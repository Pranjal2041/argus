import Foundation

@available(macOS 14.0, *)
struct LiveClaudeIntegration: UsageIntegration {
    let id = IntegrationID.claude
    var configuration: SourceConfiguration
    var client: any HTTPClient = URLSessionHTTPClient()
    var secrets: any CredentialStoring = KeychainCredentialStore()
    var descriptor: IntegrationDescriptor? { configuration.descriptor }

    func fetchSources() async throws -> [UsageSource] {
        guard let reference = configuration.credentialReference else {
            throw IntegrationError.authentication("Sign in to this Claude account in Connections.")
        }
        let values = try await ClaudeTokenRefresh.shared.validCredentials(reference: reference, secrets: secrets, client: client)
        do { return [try await reading(values)] }
        catch HTTPFailure.status(401) {
            let renewed = try await ClaudeTokenRefresh.shared.validCredentials(reference: reference, secrets: secrets, client: client,
                                                                              rejectedToken: values["accessToken"])
            do { return [try await reading(renewed)] }
            catch HTTPFailure.status(401) { throw IntegrationError.authentication("Claude rejected this login. Reconnect this account.") }
        }
        catch HTTPFailure.status(403) { throw IntegrationError.permission("Claude did not grant usage access to this account. Reconnect with a Claude subscription.") }
        catch HTTPFailure.status(429) { throw IntegrationError.unavailable("Claude is rate-limiting usage checks. The previous reading is preserved.") }
    }
    private func reading(_ values: [String: String]) async throws -> UsageSource {
        let usage = try await Self.get("usage", token: values["accessToken"] ?? "", client: client)
        return try Self.normalize(usage, configuration: configuration, email: values["email"], plan: values["plan"], now: .now)
    }
    static func get(_ path: String, token: String, client: any HTTPClient) async throws -> JSONValue {
        try await client.get(URL(string: "https://api.anthropic.com/api/oauth/\(path)")!, headers: [
            "Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20", "anthropic-version": "2023-06-01",
        ])
    }
    static func identify(_ values: [String: String], client: any HTTPClient) async throws -> [String: String] {
        let profile = try await get("profile", token: values["accessToken"] ?? "", client: client)
        guard let email = profile["account"]["email"].string ?? profile["email"].string,
              let accountID = profile["account"]["uuid"].string ?? profile["uuid"].string, !email.isEmpty, !accountID.isEmpty else {
            throw IntegrationError.invalidResponse("Claude did not report this account's identity.")
        }
        var result = values; result["email"] = email; result["accountID"] = accountID
        result["plan"] = profile["organization"]["organization_type"].string?
            .replacingOccurrences(of: "claude_", with: "").replacingOccurrences(of: "_", with: " ")
        return result
    }
    static func normalize(_ usage: JSONValue, configuration: SourceConfiguration, email: String? = nil,
                          plan: String? = nil, now: Date) throws -> UsageSource {
        func window(_ key: String, label: String, minutes: Int) throws -> QuotaWindow? {
            let value = usage[key]
            if value == .null { return nil }
            guard let used = value["utilization"].double, used.isFinite, used >= 0, used <= 100 else {
                let detail = value["utilization"].double.map { "utilization \($0)" }
                    ?? (value["utilization"] == .null ? "missing utilization" : "non-numeric utilization")
                throw IntegrationError.invalidResponse("Claude returned an invalid \(label.lowercased()) limit (\(key): \(detail)).")
            }
            return QuotaWindow(label: label, usedPercent: used, resetsAt: value["resets_at"].date, durationMinutes: minutes)
        }
        let main = try [window("five_hour", label: "5-hour", minutes: 300), window("seven_day", label: "Weekly", minutes: 10080)].compactMap { $0 }
        let names = ["seven_day_sonnet": "Sonnet", "seven_day_opus": "Opus", "seven_day_oauth_apps": "OAuth apps",
                     "seven_day_cowork": "Cowork", "seven_day_overage_included": "Fable"]
        // The weekly prefix also covers metadata such as seven_day_breakdown.
        // Known model windows remain validated; future windows must expose the
        // quota schema before being treated as limits.
        let additional = try (usage.object ?? [:]).keys.sorted().filter { key in
            key.hasPrefix("seven_day_") && (names[key] != nil || usage[key].object?["utilization"] != nil)
        }.compactMap { key -> QuotaBucket? in
            guard let item = try window(key, label: "Weekly", minutes: 10080) else { return nil }
            return QuotaBucket(id: key, name: names[key] ?? key.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "_", with: " ").capitalized, windows: [item])
        }
        guard !main.isEmpty || !additional.isEmpty else { throw IntegrationError.unavailable("Claude has not reported limits for this account yet.") }
        var source = UsageSource(id: configuration.id, integration: .claude, account: configuration.label,
            observedAt: now, payload: .quota(QuotaUsage(windows: main, additionalBuckets: additional, plan: plan)), origin: .live)
        source.accountIdentity = email
        source.notes = ["Claude subscription limits include usage shared with Claude on the web. Each account and model window resets independently."]
        return source
    }
}

/// One renewal per credential reference, even when a foreground check overlaps auto-refresh.
@available(macOS 14.0, *)
actor ClaudeTokenRefresh {
    static let shared = ClaudeTokenRefresh()
    private var pending: [String: Task<[String: String], Error>] = [:]
    func validCredentials(reference: String, secrets: any CredentialStoring, client: any HTTPClient,
                          rejectedToken: String? = nil) async throws -> [String: String] {
        if let task = pending[reference] { return try await task.value }
        let values = try secrets.read(reference: reference)
        guard let access = values["accessToken"], !access.isEmpty else {
            throw IntegrationError.authentication("Sign in to this Claude account in Connections.")
        }
        let expired = (values["expiresAt"].flatMap(Double.init) ?? 0) < Date.now.timeIntervalSince1970 + 60
        guard expired || rejectedToken == access else { return values }
        guard let refresh = values["refreshToken"], !refresh.isEmpty else {
            throw IntegrationError.authentication("This Claude login expired. Reconnect this account.")
        }
        let task = Task {
            let renewed = try await ClaudeOAuth.tokens(body: ["grant_type": "refresh_token", "refresh_token": refresh,
                "client_id": ClaudeLoginFlow.clientID, "scope": values["scope"] ?? "user:profile"], previous: values, client: client)
            try secrets.update(renewed, reference: reference)
            return renewed
        }
        pending[reference] = task
        defer { pending.removeValue(forKey: reference) }
        return try await task.value
    }
}
