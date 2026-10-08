import Foundation
import Darwin

/// Transport-level rejection is not evidence that credentials are invalid.
/// Keep raw server messages private; they can contain credential-bearing URLs.
@available(macOS 14.0, *)
struct CodexRPCFailure: Error, Sendable {
    var code: Int?
    var mayRecoverAfterAccountRefresh: Bool {
        guard let code else { return false }
        return code == -32603 || (-32099 ... -32000).contains(code)
    }
}

@available(macOS 14.0, *)
protocol CodexServing: Sendable {
    func initialize() async throws
    func request(_ method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue
    func waitForNotification(_ method: String, timeout: Double) async throws -> JSONValue
    func close(with error: Error)
}

/// A private stdio app-server connection. It never creates threads, runs models, or logs tokens.
@available(macOS 14.0, *)
final class CodexRPCSession: CodexServing, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock(), writeLock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var stopped = false
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var notifications: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var queued: [String: JSONValue] = [:]

    init(executable: String, profile: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw IntegrationError.configuration("Codex CLI is missing. Set its executable path in Connections.")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasSuffix("API_KEY") && !$0.key.hasSuffix("TOKEN_SECRET") && !$0.key.hasSuffix("TOKEN_ID")
        }
        // CODEX_HOME is used only for its documented purpose: selecting this account's login store.
        environment["CODEX_HOME"] = profile
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: profile, isDirectory: true)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            // Foundation's read(upToCount:) can wait to fill the requested buffer on a
            // pipe. One POSIX read consumes currently available protocol bytes instead.
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 { self.receive(Data(bytes.prefix(count))) }
            else if count == 0 || errno != EINTR {
                self.close(with: IntegrationError.unavailable("The Codex account service disconnected."))
            }
        }
        process.terminationHandler = { [weak self] _ in self?.close(with: IntegrationError.unavailable("The Codex account service stopped.")) }
    }

    func initialize() async throws {
        _ = try await request("initialize", params: [
            "clientInfo": .object(["name": .string("usage"), "title": .string("Usage"), "version": .string("0.2.0")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])
        try send(.object(["method": .string("initialized"), "params": .object([:])]))
    }

    func request(_ method: String, params: [String: JSONValue] = [:], timeout: Double = 25) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if stopped { lock.unlock(); continuation.resume(throwing: IntegrationError.unavailable("The Codex connection is closed.")); return }
                let id = nextID; nextID += 1; pending[id] = continuation
                lock.unlock()
                do { try send(.object(["id": .number(Double(id)), "method": .string(method), "params": .object(params)])) }
                catch { finish(id, result: .failure(IntegrationError.commandFailed)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(id, result: .failure(IntegrationError.timeout))
                }
            }
        } onCancel: { self.close(with: CancellationError()) }
    }

    func waitForNotification(_ method: String, timeout: Double = 600) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let value = queued.removeValue(forKey: method) { lock.unlock(); continuation.resume(returning: value); return }
                if stopped { lock.unlock(); continuation.resume(throwing: IntegrationError.commandFailed); return }
                notifications[method] = continuation
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); let waiting = self.notifications.removeValue(forKey: method); self.lock.unlock()
                    waiting?.resume(throwing: IntegrationError.timeout)
                }
            }
        } onCancel: { self.close(with: CancellationError()) }
    }

    func close(with error: Error = CancellationError()) {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let requests = Array(pending.values) + Array(notifications.values)
        pending.removeAll(); notifications.removeAll(); queued.removeAll()
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        for continuation in requests { continuation.resume(throwing: error) }
    }

    private func send(_ value: JSONValue) throws {
        var data = try JSONEncoder().encode(value); data.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        buffer.append(data)
        if buffer.count > 2_000_000 { lock.unlock(); close(with: IntegrationError.invalidResponse("The Codex response was too large.")); return }
        var lines: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[..<index])); buffer.removeSubrange(...index)
        }
        lock.unlock()
        for line in lines {
            guard let value = try? JSONValue.decode(line) else { continue }
            if let id = value["id"].int {
                if value["error"].object != nil {
                    // Deliberately do not expose raw server error bodies (which may contain auth URLs).
                    finish(id, result: .failure(CodexRPCFailure(code: value["error"]["code"].int)))
                } else { finish(id, result: .success(value["result"])) }
            } else if let method = value["method"].string {
                lock.lock()
                let continuation = notifications.removeValue(forKey: method)
                if continuation == nil && method == "account/login/completed" { queued[method] = value["params"] }
                lock.unlock()
                continuation?.resume(returning: value["params"])
            }
        }
    }

    private func finish(_ id: Int, result: Result<JSONValue, Error>) {
        lock.lock(); let continuation = pending.removeValue(forKey: id); lock.unlock()
        continuation?.resume(with: result)
    }
    deinit { close() }
}
