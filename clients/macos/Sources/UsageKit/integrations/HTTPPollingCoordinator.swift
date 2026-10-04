import CryptoKit
import Foundation

/// Shared by live HTTP clients, not by provider adapters. A refresh button, a
/// background refresh, and a newly constructed client must honor the same wait.
/// Only in-flight responses are shared; a successful old response is never
/// relabeled as a new live reading. Credentials and response bodies stay in memory.
@available(macOS 14.0, *)
actor HTTPPollingCoordinator {
    static let shared = HTTPPollingCoordinator()

    private struct Cooldown {
        var until: Date
        var failures: Int
        var rateLimited: Bool

        var error: IntegrationError {
            rateLimited ? .rateLimited(until: until)
                : .unavailable("The service asked to pause requests until \(until.formatted(date: .omitted, time: .shortened)). The previous reading is preserved.")
        }
    }

    private let now: @Sendable () -> Date
    private let initialBackoff: TimeInterval
    private let maximumBackoff: TimeInterval
    private var cooldowns: [String: Cooldown] = [:]
    private var pending: [String: Task<HTTPResponse, Error>] = [:]

    init(now: @escaping @Sendable () -> Date = { .now }, initialBackoff: TimeInterval = 120,
         maximumBackoff: TimeInterval = 1800) {
        self.now = now
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
    }

    func response(to request: URLRequest,
                  send: @escaping @Sendable () async throws -> HTTPResponse) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard request.url != nil else { throw IntegrationError.configuration("A usage request needs a URL.") }
        let keys = Self.keys(request)
        let started = now()
        // Do not let a completed older request overwrite a newer cooldown.
        if let cooldown = cooldowns[keys.scope], cooldown.until > started { throw cooldown.error }
        let task: Task<HTTPResponse, Error>
        if let existing = pending[keys.request] { task = existing }
        else {
            task = Task {
                defer { pending[keys.request] = nil }
                let response = try await send()
                let retryAfter = response.retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                if response.status == 429 || (response.status >= 500 && (retryAfter ?? 0) > 0) {
                    let received = now(), previous = cooldowns[keys.scope]
                    let previousFailures = previous.flatMap { $0.rateLimited ? $0.failures : nil } ?? 0
                    let failures = response.status == 429 ? previousFailures + 1 : previousFailures
                    let backoff = min(maximumBackoff, initialBackoff * pow(2, Double(min(max(0, failures - 1), 20))))
                    let delay = response.status == 429 ? max(backoff, retryAfter ?? 0) : retryAfter!
                    // Several paths may already be in flight when one is
                    // throttled. None can shorten that server's longer deadline.
                    let until = max(previous?.until ?? .distantPast, received.addingTimeInterval(delay))
                    let rateLimited = response.status == 429
                        || (previous?.rateLimited == true && previous!.until > received)
                    let cooldown = Cooldown(until: until, failures: failures, rateLimited: rateLimited)
                    cooldowns[keys.scope] = cooldown
                    // Preserve a short, explicit 5xx retry, but remember its
                    // deadline so another caller cannot cut that wait short.
                    if rateLimited || until.timeIntervalSince(received) > 5 { throw cooldown.error }
                }
                if (200..<300).contains(response.status),
                   let cooldown = cooldowns[keys.scope], cooldown.until <= started {
                    cooldowns[keys.scope] = nil
                }
                return response
            }
            pending[keys.request] = task
        }
        let response = try await task.value
        try Task.checkCancellation()
        return response
    }

    private static func keys(_ request: URLRequest) -> (scope: String, request: String) {
        let url = request.url!
        // Include every header: accounts, projects, and any future provider's
        // credential scheme must not accidentally share responses or cooldowns.
        let headers = (request.allHTTPHeaderFields ?? [:]).map { [$0.key.lowercased(), $0.value] }
            .sorted { $0[0] < $1[0] }
        let origin = [url.scheme?.lowercased() ?? "", url.host?.lowercased() ?? "",
                      String(url.port ?? (url.scheme == "https" ? 443 : 80))]
        let scope = digest((try? JSONEncoder().encode([origin] + headers)) ?? Data())
        let requestKey = digest(Data((scope + "\n" + (request.httpMethod ?? "GET") + "\n" + url.absoluteString).utf8)
            + (request.httpBody ?? Data()))
        return (scope, requestKey)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
