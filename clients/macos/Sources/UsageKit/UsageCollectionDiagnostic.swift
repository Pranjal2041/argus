import Foundation

/// Explicit, single-connection diagnostics use the real adapters without a
/// dashboard, publication, cache writes, or logging credentials/request bodies.
@available(macOS 14.0, *)
public enum UsageCollectionDiagnostic {
    public static func collect(sourceID: String) async throws -> Data {
        var configuration = try IntegrationConfiguration.load()
        guard let source = configuration.sources.first(where: { $0.id == sourceID && $0.enabled }) else {
            throw IntegrationError.configuration("Choose an enabled connection ID.")
        }
        configuration.sources = [source]
        let trace = UsageCollectionTrace()
        let started = Date()
        let registry = IntegrationRegistry.live(configuration,
            client: UsageDiagnosticHTTPClient(base: URLSessionHTTPClient(), trace: trace),
            runner: UsageDiagnosticCommandRunner(base: CommandRunner(), trace: trace))
        let results = await registry.fetchAll()
        let result = results.first!
        let report = UsageCollectionReport(sourceID: source.id, provider: source.integration.rawValue,
            startedAt: started, elapsedSeconds: Date().timeIntervalSince(started),
            sourceCount: result.sources.count, errorTitle: result.error == nil ? nil : result.errorTitle,
            transports: await trace.events)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(report)
    }
}

@available(macOS 14.0, *)
struct UsageCollectionReport: Codable {
    var sourceID: String
    var provider: String
    var startedAt: Date
    var elapsedSeconds: Double
    var sourceCount: Int
    var errorTitle: String?
    var transports: [UsageTransportEvent]
}

@available(macOS 14.0, *)
struct UsageTransportEvent: Codable, Sendable {
    var kind: String
    var destination: String
    var startedAt: Date
    var elapsedSeconds: Double
    var status: Int?
    var retryAfterSeconds: Double?
    var errorDomain: String?
    var errorCode: Int?
}

@available(macOS 14.0, *)
actor UsageCollectionTrace {
    private(set) var events: [UsageTransportEvent] = []
    func append(_ event: UsageTransportEvent) { events.append(event) }
}

@available(macOS 14.0, *)
struct UsageDiagnosticHTTPClient: HTTPClient {
    var base: any HTTPClient
    var trace: UsageCollectionTrace
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let started = Date()
        do {
            let response = try await base.send(request)
            await trace.append(.init(kind: "http", destination: request.url?.host ?? "unknown",
                startedAt: started, elapsedSeconds: Date().timeIntervalSince(started),
                status: response.status, retryAfterSeconds: response.retryAfter))
            return response
        } catch {
            let failure = error as NSError
            await trace.append(.init(kind: "http", destination: request.url?.host ?? "unknown",
                startedAt: started, elapsedSeconds: Date().timeIntervalSince(started),
                errorDomain: failure.domain, errorCode: failure.code))
            throw error
        }
    }
}

@available(macOS 14.0, *)
struct UsageDiagnosticCommandRunner: CommandRunning {
    var base: any CommandRunning
    var trace: UsageCollectionTrace
    func run(executable: String, arguments: [String], environment: [String: String], timeout: Double) async throws -> CommandOutput {
        let started = Date()
        let destination = URL(fileURLWithPath: executable).lastPathComponent
        do {
            let output = try await base.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
            await trace.append(.init(kind: "command", destination: destination, startedAt: started,
                elapsedSeconds: Date().timeIntervalSince(started), status: Int(output.status)))
            return output
        } catch {
            let failure = error as NSError
            await trace.append(.init(kind: "command", destination: destination, startedAt: started,
                elapsedSeconds: Date().timeIntervalSince(started), errorDomain: failure.domain, errorCode: failure.code))
            throw error
        }
    }
}
