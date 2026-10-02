import Foundation
import Darwin

@available(macOS 14.0, *)
struct CommandOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

@available(macOS 14.0, *)
protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: Double) async throws -> CommandOutput
}

@available(macOS 14.0, *)
struct CommandRunner: CommandRunning {
    func run(executable: String, arguments: [String], environment: [String: String] = [:], timeout: Double = 30) async throws -> CommandOutput {
        let operation = ProcessOperation(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) { try operation.run() }.value
        } onCancel: { operation.cancel() }
    }
}

/// Owns only its child process and pipes. Pipe draining runs concurrently to avoid deadlocks.
@available(macOS 14.0, *)
private final class ProcessOperation: @unchecked Sendable {
    let process = Process()
    let output = Pipe(), errors = Pipe()
    let lock = NSLock()
    var cancelled = false
    var stdout = Data(), stderr = Data()
    var oversized = false
    let timeout: Double

    init(executable: String, arguments: [String], environment: [String: String], timeout: Double) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var inherited = ProcessInfo.processInfo.environment
        // Do not pass unrelated API credentials to subprocesses.
        inherited = inherited.filter { !($0.key.hasSuffix("API_KEY") || $0.key.hasSuffix("TOKEN_SECRET") || $0.key.hasSuffix("TOKEN_ID")) }
        inherited.merge(environment) { _, new in new }
        inherited["NO_COLOR"] = "1"
        process.environment = inherited
        process.currentDirectoryURL = IntegrationConfiguration.directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        self.timeout = timeout
    }

    func run() throws -> CommandOutput {
        guard let executable = process.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw IntegrationError.configuration("A required command is missing. Check executable paths in Connections.")
        }
        if !FileManager.default.fileExists(atPath: IntegrationConfiguration.directory.path) {
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
        }
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch {
            lock.unlock()
            let failure = error as NSError
            throw IntegrationError.unavailable("Could not launch the provider command (\(failure.domain) \(failure.code)).")
        }
        lock.unlock()
        let readers = DispatchGroup()
        for isError in [false, true] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { readers.leave() }
                let handle = isError ? errors.fileHandleForReading : output.fileHandleForReading
                while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                    lock.lock()
                    let tooLarge = (isError ? stderr.count : stdout.count) + chunk.count > 8_000_000
                    if tooLarge { oversized = true }
                    else if isError { stderr.append(chunk) } else { stdout.append(chunk) }
                    lock.unlock()
                    if tooLarge { cancel(); break }
                }
            }
        }
        let timedOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        if timedOut { cancel() }
        if terminated.wait(timeout: .now() + (timedOut ? 1 : 0)) == .timedOut, process.isRunning {
            signalOwnedProcess(SIGKILL)
        }
        if readers.wait(timeout: .now() + 2) == .timedOut {
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        if timedOut { throw IntegrationError.timeout }
        lock.lock(); defer { lock.unlock() }
        if oversized { throw IntegrationError.invalidResponse("The provider response exceeded the safety limit.") }
        if cancelled { throw CancellationError() }
        return CommandOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    func cancel() {
        lock.lock(); cancelled = true; let running = process.isRunning; lock.unlock()
        if running { signalOwnedProcess(SIGTERM) }
    }
    private func signalOwnedProcess(_ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // NSTask normally creates a process group. Never signal a group we don't own.
        if getpgid(pid) == pid { kill(-pid, signal) } else { kill(pid, signal) }
    }
}
