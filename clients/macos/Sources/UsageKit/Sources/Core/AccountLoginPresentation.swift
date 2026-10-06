import Foundation

/// Authentication belongs to the collector; presentation belongs to the client
/// that requested this particular attempt. These IDs are correlation, not credentials.
struct AccountLoginContext: Sendable {
    enum Presenter: Sendable { case local, requestingClient }
    var id = UUID().uuidString
    var presenter: Presenter = .local
}

/// Polling may discover a URL later, but must never create new browser intent.
struct AccountLoginHandoff {
    private var requestedAttemptID: String?
    private var consumed = false

    mutating func begin(_ id: String) {
        requestedAttemptID = id
        consumed = false
    }

    mutating func reset() { requestedAttemptID = nil; consumed = false }

    mutating func consume(attemptID: String?, url: URL?, automatically: Bool) -> URL? {
        guard let requestedAttemptID else { return nil }
        guard attemptID == requestedAttemptID else { reset(); return nil }
        guard automatically, !consumed, let url else { return nil }
        // Consume even a failed launch: retries require another explicit click.
        consumed = true
        return Self.isSafe(url) ? url : nil
    }

    static func isSafe(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
            && (url.port == nil || (1...65535).contains(url.port!))
    }
}
