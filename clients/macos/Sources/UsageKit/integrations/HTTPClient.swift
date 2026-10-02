import Foundation

@available(macOS 14.0, *)
struct HTTPResponse: Sendable {
    var status: Int
    var data: Data
    var retryAfter: Double?
}

@available(macOS 14.0, *)
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
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
    init() {
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
        return HTTPResponse(status: response.statusCode, data: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
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
            let response = try await send(request)
            if (response.status == 429 || response.status >= 500), attempt == 0 {
                try await Task.sleep(for: .seconds(min(5, max(0.5, response.retryAfter ?? 1))))
                continue
            }
            guard (200..<300).contains(response.status) else { throw HTTPFailure.status(response.status) }
            return try JSONValue.decode(response.data)
        }
        throw IntegrationError.unavailable("The service is temporarily unavailable.")
    }
}
