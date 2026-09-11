import CryptoKit
import Foundation

/// Reads the OAuth access token that Claude Code / the Claude CLI stores.
///
/// On macOS Claude Code keeps the token in a Keychain generic-password item;
/// older/other setups keep it in `<config dir>/.credentials.json`. We try the
/// Keychain first, then the file, locating both the way Claude Code does.
///
/// The Keychain is read through `/usr/bin/security` rather than the Security
/// framework. Claude Code writes the item with that tool, so it is already on
/// the item's access list and reads don't prompt. Reading the item directly
/// would make this app the requester, and "Always Allow" would pin to its
/// ad-hoc signature — a hash of the exact binary that every rebuild or
/// upgrade changes, bringing the prompt back each time.
enum ClaudeCredentials {

    struct Token {
        let accessToken: String
        let subscriptionType: String?
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }
    }

    /// Why the Keychain read failed. `notFound` falls through to the file
    /// silently; the rest are reported if the file doesn't have a token either.
    enum KeychainError: LocalizedError {
        case notFound
        case locked
        case denied
        case timedOut
        case malformed
        case failed(status: Int32, message: String)

        /// A Keychain prompt was shown and not approved (denied, or left
        /// unanswered until the timeout). Retrying on a timer would only
        /// prompt again and again, nudging the user toward "Always Allow".
        var promptNotApproved: Bool {
            switch self {
            case .denied, .timedOut: return true
            default: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .notFound: return "Keychain item not found"
            case .locked: return "Keychain locked"
            case .denied: return "Keychain access denied"
            case .timedOut: return "Keychain read timed out"
            case .malformed: return "Unreadable Claude credentials"
            case .failed(let status, let message):
                return message.isEmpty
                    ? "Keychain read failed (exit \(status))"
                    : "Keychain read failed (exit \(status): \(message))"
            }
        }
    }

    /// Where Claude Code keeps its credentials for the current environment.
    struct Location {
        let service: String
        let account: String
        let filePath: String
    }

    /// Long enough to answer a Keychain prompt should one appear; the poll
    /// retries on the next cycle anyway.
    private static let keychainTimeout: TimeInterval = 30

    /// A credentials blob is a few KB; anything far larger isn't one.
    private static let maxOutputBytes = 1 << 20

    static func load() async throws -> Token {
        let location = Location.current()

        var keychainError: Error?
        do {
            let data = try await keychainData(service: location.service, account: location.account)
            if let token = parse(data) { return token }
            keychainError = KeychainError.malformed
        } catch KeychainError.notFound {
            // Not in the Keychain — expected for file-based setups.
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            keychainError = error
        }

        if let data = FileManager.default.contents(atPath: location.filePath),
           let token = parse(data) {
            return token
        }
        throw keychainError ?? UsageError.notAuthenticated("run `claude` to sign in")
    }

    /// Parse the `{ "claudeAiOauth": { "accessToken": …, "expiresAt": … } }` blob.
    ///
    /// `security -w` prints the value as hex when it contains bytes it doesn't
    /// consider printable (e.g. non-ASCII or newlines), so fall back to
    /// hex-decoding when the bytes aren't JSON as-is.
    private static func parse(_ data: Data) -> Token? {
        guard let root = jsonObject(data) ?? hexDecoded(data).flatMap(jsonObject),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              !access.isEmpty else {
            return nil
        }
        // expiresAt is epoch milliseconds.
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let ms = oauth["expiresAt"] as? Int {
            expires = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        return Token(accessToken: access,
                     subscriptionType: oauth["subscriptionType"] as? String,
                     expiresAt: expires)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Decode whitespace-trimmed hex digit pairs, or nil if `data` isn't that.
    private static func hexDecoded(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let digits = Array(text.utf8)
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let high = hexValue(digits[i]), let low = hexValue(digits[i + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: - Keychain

    /// Read a generic-password value via
    /// `security find-generic-password -a <account> -w -s <service>` — the same
    /// lookup Claude Code performs. Searches the default keychain search list.
    private static func keychainData(service: String, account: String) async throws -> Data {
        let result = try await SecurityCommand.run(
            ["find-generic-password", "-a", account, "-w", "-s", service],
            timeout: keychainTimeout,
            maxOutputBytes: maxOutputBytes
        )
        // `security` exits with the low byte of the Security framework status.
        switch result.status {
        case 0:
            return result.stdout
        case 44: // errSecItemNotFound
            throw KeychainError.notFound
        case 36: // errSecInteractionNotAllowed — keychain locked, no UI
            throw KeychainError.locked
        case 51, 128: // errSecAuthFailed (denied), userCanceledErr
            throw KeychainError.denied
        default:
            throw KeychainError.failed(status: result.status, message: result.stderrSummary)
        }
    }
}

extension ClaudeCredentials.Location {

    /// Resolve the Keychain service, account, and credentials file the way
    /// Claude Code does. A GUI launch doesn't inherit shell variables, so the
    /// `CLAUDE_*` overrides only apply when the app is started from a terminal.
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                        userName: String = NSUserName(),
                        home: String = NSHomeDirectory()) -> Self {
        let defaultDir = (home as NSString).appendingPathComponent(".claude")
        let secureDir = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        let configDir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }

        let isDefault: Bool
        let storageDir: String
        if let secureDir {
            isDefault = secureDir.isEmpty
            storageDir = secureDir.isEmpty ? defaultDir : secureDir
        } else {
            isDefault = configDir == nil
            storageDir = configDir ?? defaultDir
        }
        let normalizedDir = storageDir.precomposedStringWithCanonicalMapping

        // Non-default config dirs get their own item, suffixed with a short
        // hash of the directory so several installs don't collide.
        var service = "Claude Code-credentials"
        if !isDefault {
            let hex = SHA256.hash(data: Data(normalizedDir.utf8))
                .map { String(format: "%02x", $0) }.joined()
            service += "-" + String(hex.prefix(8))
        }

        return Self(service: service,
                    account: account(environment: environment, userName: userName),
                    filePath: (normalizedDir as NSString).appendingPathComponent(".credentials.json"))
    }

    /// `$USER`, else the login name; Claude Code substitutes a fixed name when
    /// that contains anything outside `[A-Za-z0-9._-]`.
    private static func account(environment: [String: String], userName: String) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? userName
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
            return "claude-code-user"
        }
        return name
    }
}

/// Runs `/usr/bin/security` with a timeout, cancellation, and bounded output.
private enum SecurityCommand {

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data

        /// First line of stderr, capped — enough to diagnose, short enough for
        /// the menu. `security` only writes status messages there.
        var stderrSummary: String {
            let text = String(decoding: stderr, as: UTF8.self)
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(line.prefix(120))
        }
    }

    static func run(_ arguments: [String],
                    timeout: TimeInterval,
                    maxOutputBytes: Int) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let control = Control(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try control.launch()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let timer = DispatchWorkItem { control.stop(.timedOut) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                    // Drain both pipes before waiting so neither can stall the
                    // child on a full buffer.
                    let group = DispatchGroup()
                    let errData = DataBox()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errData.value = readBounded(stderr, limit: 64 * 1024, control: control)
                        group.leave()
                    }
                    let outData = readBounded(stdout, limit: maxOutputBytes, control: control)
                    group.wait()
                    process.waitUntilExit()
                    timer.cancel()

                    switch control.stopReason {
                    case .timedOut?:
                        continuation.resume(throwing: ClaudeCredentials.KeychainError.timedOut)
                    case .cancelled?:
                        continuation.resume(throwing: CancellationError())
                    case .outputTooLarge?:
                        continuation.resume(throwing: ClaudeCredentials.KeychainError.malformed)
                    case nil:
                        continuation.resume(returning: Result(status: process.terminationStatus,
                                                              stdout: outData,
                                                              stderr: errData.value))
                    }
                }
            }
        } onCancel: {
            control.stop(.cancelled)
        }
    }

    /// Read until EOF, stopping the process if it writes more than `limit`.
    private static func readBounded(_ pipe: Pipe, limit: Int, control: Control) -> Data {
        let handle = pipe.fileHandleForReading
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return data }
            if data.count + chunk.count > limit {
                control.stop(.outputTooLarge)
                // Keep draining so the child isn't left blocked on a write.
                while !handle.availableData.isEmpty {}
                return data
            }
            data.append(chunk)
        }
    }

    enum StopReason {
        case timedOut, cancelled, outputTooLarge
    }

    /// Carries the stderr read back from its queue; written once, before
    /// `group.wait()` returns.
    final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    /// Serializes launch and termination: `Process.terminate()` raises if the
    /// process hasn't launched, and cancellation can arrive at any point.
    final class Control: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var launched = false
        private var reason: StopReason?

        init(_ process: Process) {
            self.process = process
        }

        var stopReason: StopReason? {
            lock.lock(); defer { lock.unlock() }
            return reason
        }

        func launch() throws {
            lock.lock(); defer { lock.unlock() }
            if reason == .cancelled { throw CancellationError() }
            try process.run()
            launched = true
        }

        /// Record why the process is being stopped (first reason wins) and
        /// terminate it if still running. No-op once it has exited normally.
        func stop(_ why: StopReason) {
            lock.lock(); defer { lock.unlock() }
            if launched && !process.isRunning { return }
            if reason == nil { reason = why }
            if launched { process.terminate() }
        }
    }
}
