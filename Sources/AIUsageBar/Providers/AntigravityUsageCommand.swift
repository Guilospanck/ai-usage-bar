import Darwin
import Foundation

/// Runs a built-in CLI command, not a model prompt. Never exposes raw stderr.
enum AntigravityUsageCommand {
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> URL
    {
        let fm = FileManager.default
        if let override = environment["ANTIGRAVITY_CLI_PATH"] {
            guard override.hasPrefix("/"), fm.isExecutableFile(atPath: override) else {
                throw UsageError.badResponse("ANTIGRAVITY_CLI_PATH must point to an executable agy")
            }
            return URL(fileURLWithPath: override)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let paths =
            (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [
                "\(home)/.local/bin", "\(home)/.antigravity/bin", "/opt/homebrew/bin",
                "/usr/local/bin",
            ]
        for directory in paths where directory.hasPrefix("/") {
            let path = directory + "/agy"
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        throw UsageError.notAuthenticated("install agy and run it once to sign in")
    }

    static func run() async throws -> Data {
        try Task.checkCancellation()
        let executable = try executable()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(
            "ai-usage-bar-agy-\(UUID().uuidString)")
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        // agy can launch a browser when silent refresh fails. Timer polls must not do that.
        for name in ["open", "xdg-open", "browser"] {
            let file = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "60s"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["BROWSER"] = directory.appendingPathComponent("browser").path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let control = Control(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { try control.launch() } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let timer = DispatchWorkItem { control.stop("agy usage timed out") }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 75, execute: timer)
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        _ = drain(errors, control: control)
                        group.leave()
                    }
                    let data = drain(output, control: control)
                    group.wait()
                    process.waitUntilExit()
                    timer.cancel()
                    if let reason = control.reason {
                        if reason == "cancelled" {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: UsageError.badResponse(reason))
                        }
                    } else if process.terminationStatus != 0 {
                        continuation.resume(
                            throwing: UsageError.badResponse(
                                "agy usage failed; run `agy` to check sign-in (exit \(process.terminationStatus))"
                            ))
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
        } onCancel: {
            control.stop("cancelled")
        }
    }

    private static func drain(_ pipe: Pipe, control: Control) -> Data {
        let handle = pipe.fileHandleForReading
        defer { try? handle.close() }
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while control.reason == nil {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                control.stop("Could not read agy usage output")
                return data
            }
            if data.count + count > 1 << 20 {
                control.stop("agy usage output exceeded 1 MiB")
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private final class Control: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var launched = false
        private var stopReason: String?

        init(_ process: Process) { self.process = process }

        var reason: String? {
            lock.lock()
            defer { lock.unlock() }
            return stopReason
        }

        func launch() throws {
            lock.lock()
            defer { lock.unlock() }
            if stopReason != nil { throw CancellationError() }
            try process.run()
            launched = true
        }

        func stop(_ reason: String) {
            lock.lock()
            defer { lock.unlock() }
            guard stopReason == nil else { return }
            if launched && !process.isRunning { return }
            stopReason = reason
            if launched {
                process.terminate()
                // Escalate if the CLI ignores SIGTERM.
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                    lock.lock()
                    defer { lock.unlock() }
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }
}
