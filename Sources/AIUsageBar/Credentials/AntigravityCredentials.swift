import CryptoKit
import Foundation

/// Reads the OAuth access token that Antigravity CLI stores.
///
/// On macOS Antigravity keeps the token in a Keychain generic-password item;
///
enum AntigravityCredentials {

    struct OAuthToken: Decodable {
        let accessToken: String
        let tokenType: String
        let refreshToken: String
        let expiry: Date

        var isExpired: Bool {
            return expiry < Date()
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case expiry
        }
    }

    struct Token: Decodable {

        let token: OAuthToken
        let authMethod: String
        let idToken: String

        enum CodingKeys: String, CodingKey {
            case token
            case authMethod = "auth_method"
            case idToken = "id_token"
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
            case .malformed: return "Unreadable Antigravity credentials"
            case .failed(let status, let message):
                return message.isEmpty
                    ? "Keychain read failed (exit \(status))"
                    : "Keychain read failed (exit \(status): \(message))"
            }
        }
    }

    /// Where Antigravity keeps its credentials for the current environment.
    struct Location {
        let service: String
        let account: String
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
            guard let raw = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformed
            }
            if let token = parse(raw) { return token }
            keychainError = KeychainError.malformed
        } catch KeychainError.notFound {
            // Not in the Keychain — expected for file-based setups.
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            keychainError = error
        }

        throw keychainError ?? UsageError.notAuthenticated("run `claude` to sign in")
    }

    private static func parse(_ raw: String) -> Token? {
        let prefix = "go-keyring-base64:"

        guard raw.hasPrefix(prefix) else {
            return nil
        }

        let encoded = String(raw.dropFirst(prefix.count))

        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let token: AntigravityCredentials.Token
        do {
            token = try decoder.decode(AntigravityCredentials.self.Token, from: data)
        } catch {
            return nil
        }

        return token
    }

    // MARK: - Keychain

    /// Read a generic-password value via
    /// `security find-generic-password -a <account> -w -s <service>`.
    /// Searches the default keychain search list.
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
        case 44:  // errSecItemNotFound
            throw KeychainError.notFound
        case 36:  // errSecInteractionNotAllowed — keychain locked, no UI
            throw KeychainError.locked
        case 51, 128:  // errSecAuthFailed (denied), userCanceledErr
            throw KeychainError.denied
        default:
            throw KeychainError.failed(status: result.status, message: result.stderrSummary)
        }
    }
}

extension AntigravityCredentials.Location {
    static func current() -> Self {

        let service = "gemini"
        let account = "antigravity"

        return Self(service: service, account: account)
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

    static func run(
        _ arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> Result {
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
                        continuation.resume(throwing: AntigravityCredentials.KeychainError.timedOut)
                    case .cancelled?:
                        continuation.resume(throwing: CancellationError())
                    case .outputTooLarge?:
                        continuation.resume(
                            throwing: AntigravityCredentials.KeychainError.malformed)
                    case nil:
                        continuation.resume(
                            returning: Result(
                                status: process.terminationStatus,
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
            lock.lock()
            defer { lock.unlock() }
            return reason
        }

        func launch() throws {
            lock.lock()
            defer { lock.unlock() }
            if reason == .cancelled { throw CancellationError() }
            try process.run()
            launched = true
        }

        /// Record why the process is being stopped (first reason wins) and
        /// terminate it if still running. No-op once it has exited normally.
        func stop(_ why: StopReason) {
            lock.lock()
            defer { lock.unlock() }
            if launched && !process.isRunning { return }
            if reason == nil { reason = why }
            if launched { process.terminate() }
        }
    }
}
