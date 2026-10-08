import Foundation
import Darwin

/// Shared external-process contract: concurrent pipe draining, bounded output,
/// a wall-clock deadline, and cancellation that terminates only the owned child
/// (and its process group, when Foundation created one).
struct BoundedProcessRunner {
    struct Output: Sendable { let status: Int32; let stdout: Data }
    enum Failure: Error { case timedOut, oversizedOutput, didNotExit }

    var timeout: TimeInterval = 90
    var terminationGrace: TimeInterval = 1
    var maximumOutputBytes = 2 * 1024 * 1024

    func run(executable: URL, arguments: [String], input: Data = Data(),
             directory: URL = FileManager.default.temporaryDirectory) async throws -> Output {
        let operation = BoundedProcessOperation(executable: executable, arguments: arguments, input: input,
                                                directory: directory, limits: self)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) { try operation.run() }.value
        } onCancel: { operation.cancel() }
    }
}

private final class BoundedProcessOperation: @unchecked Sendable {
    private let process = Process(), inputPipe = Pipe(), outputPipe = Pipe()
    private let input: Data, limits: BoundedProcessRunner
    private let lock = NSLock()
    private var cancelled = false, oversized = false, stopReading = false, stopWriting = false
    private var stdout = Data()

    init(executable: URL, arguments: [String], input: Data, directory: URL, limits: BoundedProcessRunner) {
        self.input = input; self.limits = limits
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardInput = inputPipe; process.standardOutput = outputPipe; process.standardError = FileHandle.nullDevice
    }

    func run() throws -> BoundedProcessRunner.Output {
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0), written = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        defer {
            try? outputPipe.fileHandleForReading.close()
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { try? inputPipe.fileHandleForWriting.close(); written.signal() }
            let fd = inputPipe.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            // A child may exit without reading its prompt. Broken stdin must
            // neither terminate the collector via SIGPIPE nor block cleanup.
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            input.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count && !lock.withLock({ stopWriting }) {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard poll(&descriptor, 1, 50) > 0 else { continue }
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(16 * 1024, bytes.count - offset))
                    if count > 0 { offset += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { break }
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { drained.signal() }
            let fd = outputPipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while !lock.withLock({ stopReading }) {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                guard poll(&descriptor, 1, 50) > 0 else { continue }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
                let chunk = Data(buffer.prefix(count))
                let tooLarge = lock.withLock { () -> Bool in
                    if stdout.count + chunk.count > limits.maximumOutputBytes { oversized = true; return true }
                    stdout.append(chunk); return false
                }
                if tooLarge { cancel(); break }
            }
        }
        let timedOut = exited.wait(timeout: .now() + limits.timeout) == .timedOut
        if timedOut {
            cancel()
            _ = exited.wait(timeout: .now() + limits.terminationGrace + 1)
        }
        lock.withLock { stopWriting = true }
        _ = written.wait(timeout: .now() + 0.2)
        // A descendant must not keep stdout open after its parent exits. Never
        // turn pipe draining into another unbounded wait.
        if drained.wait(timeout: .now() + 1) == .timedOut {
            lock.withLock { stopReading = true }
            _ = drained.wait(timeout: .now() + 0.2)
        }
        guard !process.isRunning else { throw BoundedProcessRunner.Failure.didNotExit }
        if timedOut { throw BoundedProcessRunner.Failure.timedOut }
        return try lock.withLock {
            if oversized { throw BoundedProcessRunner.Failure.oversizedOutput }
            if cancelled { throw CancellationError() }
            return BoundedProcessRunner.Output(status: process.terminationStatus, stdout: stdout)
        }
    }

    func cancel() {
        let first = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            cancelled = true; return true
        }
        guard first, process.isRunning else { return }
        signalOwned(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limits.terminationGrace) { [self] in
            if process.isRunning { signalOwned(SIGKILL) }
        }
    }

    private func signalOwned(_ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        if getpgid(pid) == pid { kill(-pid, signal) } else { kill(pid, signal) }
    }
}
