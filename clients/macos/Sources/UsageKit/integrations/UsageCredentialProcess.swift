import Foundation
import Darwin

@available(macOS 14.0, *)
struct UsageCredentialRequest: Codable, Sendable {
    enum Operation: String, Codable { case read, update }
    var operation: Operation
    var reference: String
    var values: [String: String]?
}

@available(macOS 14.0, *)
struct UsageCredentialResponse: Codable, Sendable {
    var values: [String: String]?
    var error: String?
}

@available(macOS 14.0, *)
protocol UsageCredentialRunning: Sendable {
    func perform(_ request: UsageCredentialRequest) throws -> UsageCredentialResponse
}

/// Launch the same signed executable, so an explicit Argus Keychain grant also
/// authorizes its worker. Secrets travel only through private pipes, never argv,
/// environment, temporary files, diagnostics, or a shell.
@available(macOS 14.0, *)
struct UsageCredentialProcess: UsageCredentialRunning {
    var executable: URL? = Bundle.main.executableURL

    func perform(_ request: UsageCredentialRequest) throws -> UsageCredentialResponse {
        guard let executable else { throw IntegrationError.configuration("The Argus credential worker is unavailable.") }
        let data = try JSONEncoder().encode(request)
        guard data.count <= UsageCredentialWorker.maximumMessageBytes else {
            throw IntegrationError.configuration("The credential message is too large.")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = [UsageCredentialWorker.argument]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        // Bound Keychain service stalls without touching any other process.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel(); try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let response = try output.fileHandleForReading.readToEnd() ?? Data()
        _ = completed.wait(timeout: .now() + 1)
        guard !process.isRunning, process.terminationStatus == 0,
              response.count <= UsageCredentialWorker.maximumMessageBytes,
              let decoded = try? JSONDecoder().decode(UsageCredentialResponse.self, from: response) else {
            throw IntegrationError.authentication("The saved key could not be read. Check this account in Connections.")
        }
        if let error = decoded.error { throw IntegrationError.authentication(error) }
        return decoded
    }
}

/// Invoked before the app lifecycle: no windows, brokers, browser, polling, or
/// sign-in UI starts in this process. Its scope is the Usage Keychain service.
@available(macOS 14.0, *)
public enum UsageCredentialWorker {
    public static let argument = "--usage-keychain-worker"
    static let maximumMessageBytes = 256 * 1024

    public static func runIfRequested() {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == argument else { return }
        do {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 16 * 1024), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumMessageBytes else { exit(2) }
            }
            let request = try JSONDecoder().decode(UsageCredentialRequest.self, from: data)
            guard !request.reference.isEmpty, request.reference.utf8.count <= 512 else { exit(2) }
            let store = KeychainCredentialStore(isWorker: true)
            let response: UsageCredentialResponse
            do {
                switch request.operation {
                case .read: response = UsageCredentialResponse(values: try store.read(reference: request.reference))
                case .update:
                    guard let values = request.values else { exit(2) }
                    try store.update(values, reference: request.reference)
                    response = UsageCredentialResponse()
                }
            } catch {
                response = UsageCredentialResponse(error: (error as? IntegrationError)?.errorDescription ?? "The saved credential is unavailable.")
            }
            let output = try JSONEncoder().encode(response)
            guard output.count <= maximumMessageBytes else { exit(2) }
            try FileHandle.standardOutput.write(contentsOf: output)
            exit(0)
        } catch { exit(2) }
    }
}
