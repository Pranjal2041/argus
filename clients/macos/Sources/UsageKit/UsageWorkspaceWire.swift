import Foundation

// This envelope contains normalized readings and presentation, never connection
// configurations, executable arguments, cookie jars, or credential references.
@available(macOS 14.0, *)
enum UsageWorkspaceWire {
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }
    struct Settings: Codable {
        var policy: UsageAlertPolicy
        var refreshSeconds: Double
        var cardOrder: [String]
    }
    struct Failure: Codable {
        var integration: IntegrationID
        var sourceID: String?
        var message: String
        var needsAuthentication: Bool
        var errorTitle: String? = nil
    }
    struct Account: Codable {
        var id: String
        var title: String
        var account: String
        var observedAt: Date
        var stale: Bool
        var status: String
        var notes: [String]
        var cards: [UsageGlance]
    }
    struct Snapshot: Codable {
        var version: Int
        var observedAt: Date
        var lastRefresh: Date?
        var sources: [UsageSource]
        var glances: [UsageGlance]
        var warnings: [UsageWarning]
        var failures: [Failure]
        var accounts: [Account]
    }
}
