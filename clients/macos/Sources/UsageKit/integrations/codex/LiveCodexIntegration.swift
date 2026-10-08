import Foundation

@available(macOS 14.0, *)
struct LiveCodexIntegration: UsageIntegration {
    let id = IntegrationID.codex
    let configuration: SourceConfiguration
    let executable: String
    var makeSession: @Sendable (String, String) throws -> any CodexServing = { try CodexRPCSession(executable: $0, profile: $1) }
    var descriptor: IntegrationDescriptor? { configuration.descriptor }

    func fetchSources() async throws -> [UsageSource] {
        guard let profile = configuration.codexHome,
              FileManager.default.fileExists(atPath: profile) else {
            throw IntegrationError.authentication("Connect this Codex account to see its limits.")
        }
        let session = try makeSession(executable, profile)
        defer { session.close(with: CancellationError()) }
        try await session.initialize()
        var refreshed = false
        func readAccount(refresh: Bool) async throws -> JSONValue {
            let response = try await session.request("account/read", params: ["refreshToken": .bool(refresh)], timeout: 25)
            guard let account = response.object?["account"] else {
                throw IntegrationError.invalidResponse("Codex did not return an account status. Check the CLI installation and try again.")
            }
            return account
        }
        var account = try await readAccount(refresh: false)
        if account == .null {
            account = try await readAccount(refresh: true)
            refreshed = true
        }
        try Self.validateAccount(account, configuration: configuration)
        var expectedAccount = configuration
        if expectedAccount.accountIdentity == nil { expectedAccount.accountIdentity = account["email"].string }
        let rates: JSONValue
        do {
            rates = try await session.request("account/rateLimits/read", params: [:], timeout: 25)
        } catch {
            // The CLI owns credential renewal. Retry once through its public
            // account API; never replace profiles or reuse another account.
            let canRefresh = (error as? IntegrationError)?.needsAuthentication == true
                || (error as? CodexRPCFailure)?.mayRecoverAfterAccountRefresh == true
            guard !refreshed, canRefresh else { throw error }
            try Task.checkCancellation()
            account = try await readAccount(refresh: true)
            try Self.validateAccount(account, configuration: expectedAccount)
            rates = try await session.request("account/rateLimits/read", params: [:], timeout: 25)
        }
        return [try Self.normalize(account: account, rates: rates, configuration: configuration, now: .now)]
    }

    static func validateAccount(_ account: JSONValue, configuration: SourceConfiguration) throws {
        switch account["type"].string {
        case "chatgpt": try configuration.validateAccountIdentity(account["email"].string)
        case "apiKey":
            throw IntegrationError.authentication("This profile uses an API key. Sign in with a ChatGPT account to see its quota windows.")
        case nil where account == .null:
            throw IntegrationError.authentication("This profile has no active ChatGPT login after refreshing. Sign in again to restore live usage.")
        default:
            throw IntegrationError.invalidResponse("This profile did not report a supported ChatGPT account. Check its Codex login and try again.")
        }
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
