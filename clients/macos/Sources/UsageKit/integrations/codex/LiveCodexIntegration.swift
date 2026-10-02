import Foundation

@available(macOS 14.0, *)
struct LiveCodexIntegration: UsageIntegration {
    let id = IntegrationID.codex
    let configuration: SourceConfiguration
    let executable: String
    var descriptor: IntegrationDescriptor? { configuration.descriptor }

    func fetchSources() async throws -> [UsageSource] {
        guard let profile = configuration.codexHome,
              FileManager.default.fileExists(atPath: profile) else {
            throw IntegrationError.authentication("Connect this Codex account to see its limits.")
        }
        let session = try CodexRPCSession(executable: executable, profile: profile)
        defer { session.close() }
        try await session.initialize()
        let account = try await session.request("account/read", params: ["refreshToken": .bool(false)])["account"]
        guard account["type"].string == "chatgpt" else {
            throw IntegrationError.authentication("Sign in with a ChatGPT account. API-key logins do not expose ChatGPT quota windows.")
        }
        let rates = try await session.request("account/rateLimits/read")
        return [try Self.normalize(account: account, rates: rates, configuration: configuration, now: .now)]
    }

    static func normalize(account: JSONValue, rates: JSONValue, configuration: SourceConfiguration, now: Date) throws -> UsageSource {
        try configuration.validateAccountIdentity(account["email"].string)
        let buckets = rates["rateLimitsByLimitId"].object ?? [:]
        let main = buckets["codex"] ?? rates["rateLimits"]
        guard main.object != nil else { throw IntegrationError.invalidResponse("Codex did not report any quota information.") }
        let additional = try buckets.keys.sorted().filter { $0 != "codex" }.map { key in
            QuotaBucket(id: key, name: buckets[key]?["limitName"].string ?? key,
                        windows: try windows(buckets[key] ?? .null))
        }
        let quota = QuotaUsage(windows: try windows(main), additionalBuckets: additional,
                               plan: account["planType"].string ?? main["planType"].string,
                               credits: main["credits"]["balance"].string,
                               resetCreditsAvailable: rates["rateLimitResetCredits"]["availableCount"].int)
        var source = UsageSource(id: configuration.id, integration: .codex,
                                 account: configuration.label, observedAt: now,
                                 payload: .quota(quota), origin: .live)
        source.accountIdentity = account["email"].string
        source.notes = ["Reported by Codex CLI. Windows and model buckets are kept separate; missing windows are not treated as 0%."]
        return source
    }

    static func windows(_ bucket: JSONValue) throws -> [QuotaWindow] {
        try ["primary", "secondary"].compactMap { key in
            let value = bucket[key]
            guard value.object != nil else { return nil }
            guard let used = value["usedPercent"].double, used.isFinite, used >= 0 else {
                throw IntegrationError.invalidResponse("Codex returned an invalid quota percentage.")
            }
            let minutes = value["windowDurationMins"].int
            let label: String
            switch minutes {
            case 10080: label = "Weekly"
            case 1440: label = "Daily"
            case .some(let minutes) where minutes > 0 && minutes % 60 == 0: label = "\(minutes / 60)-hour"
            case .some(let minutes) where minutes > 0: label = "\(minutes)-minute"
            default: label = key == "primary" ? "Primary" : "Secondary"
            }
            return QuotaWindow(label: label, usedPercent: used, resetsAt: value["resetsAt"].date, durationMinutes: minutes)
        }
    }
}
