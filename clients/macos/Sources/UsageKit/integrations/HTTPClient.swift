import Foundation

@available(macOS 14.0, *)
struct HTTPResponse: Sendable {
    var status: Int
    var data: Data
    var retryAfter: Double?
}

@available(macOS 14.0, *)
protocol HTTPClient: Sendable {
    var pollingCoordinator: HTTPPollingCoordinator { get }
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

@available(macOS 14.0, *)
extension HTTPClient {
    var pollingCoordinator: HTTPPollingCoordinator { .shared }
}

@available(macOS 14.0, *)
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        completionHandler(request.url?.host == original?.host && request.url?.scheme == "https" ? request : nil)
    }
}

@available(macOS 14.0, *)
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    let pollingCoordinator: HTTPPollingCoordinator
    init(pollingCoordinator: HTTPPollingCoordinator = .shared) {
        self.pollingCoordinator = pollingCoordinator
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 16_000_000 else {
            throw IntegrationError.invalidResponse("The service returned an invalid or oversized response.")
        }
        return HTTPResponse(status: response.statusCode, data: data,
                            retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
    }

    static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // HTTP-date permits the current wire format and the two legacy formats.
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}

@available(macOS 14.0, *)
enum HTTPFailure: Error, Sendable { case status(Int) }

@available(macOS 14.0, *)
extension HTTPClient {
    func get(_ url: URL, headers: [String: String]) async throws -> JSONValue {
        guard url.scheme == "https" else { throw IntegrationError.configuration("Provider URLs must use HTTPS.") }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Usage/0.2.0", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let outgoing = request
            let response = try await pollingCoordinator.response(to: outgoing) { try await self.send(outgoing) }
            if response.status >= 500, attempt == 0 {
                let delay = response.retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 1
                // Long Retry-After deadlines and all 429s have already been
                // deferred by the coordinator; only a short 5xx retry gets here.
                try await Task.sleep(for: .seconds(max(0.5, delay)))
                continue
            }
            guard (200..<300).contains(response.status) else { throw HTTPFailure.status(response.status) }
            return try JSONValue.decode(response.data)
        }
        throw IntegrationError.unavailable("The service is temporarily unavailable.")
    }
}
