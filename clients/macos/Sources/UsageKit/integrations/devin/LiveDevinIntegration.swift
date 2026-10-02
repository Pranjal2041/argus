import Foundation

/// Read-only CLI boundary: the CLI owns credentials and enterprise routing,
/// but account selection is always the connection's explicit private profile.
@available(macOS 14.0, *)
struct LiveDevinIntegration: UsageIntegration {
    let id = IntegrationID.devin
    let configuration: SourceConfiguration
    let executable: String
    var runner: any CommandRunning = CommandRunner()
    var descriptor: IntegrationDescriptor? { configuration.descriptor }

    func fetchSources() async throws -> [UsageSource] {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw IntegrationError.configuration("Install Devin CLI, then sign in to this account in Connections.")
        }
        guard let path = configuration.accountProfile else {
            throw IntegrationError.authentication("Sign in to this Devin account in Connections. Each connection has its own private login.")
        }
        let profile = try AccountProfile(path: path)
        let result = try await runner.run(executable: executable, arguments: ["auth", "status"],
            environment: profile.environment, timeout: 30)
        guard result.status == 0 else {
            throw IntegrationError.authentication("Devin CLI could not check this account. Sign in again in Connections.")
        }
        return [try Self.normalize(String(decoding: result.stdout + result.stderr, as: UTF8.self), configuration: configuration, now: .now)]
    }

    static func normalize(_ output: String, configuration: SourceConfiguration, now: Date) throws -> UsageSource {
        let text = DevinOutput.plain(output)
        let email = DevinOutput.captures("(?im)^\\s*Email:\\s*(\\S+)$", text).first
        try configuration.validateAccountIdentity(email)
        guard text.localizedCaseInsensitiveContains("Logged in") && !text.localizedCaseInsensitiveContains("Not logged in") else {
            throw IntegrationError.authentication("Sign in to this Devin account in Connections, then check it again.")
        }
        guard !text.localizedCaseInsensitiveContains("Failed to fetch quota"),
              !text.localizedCaseInsensitiveContains("No quota data"), !text.localizedCaseInsensitiveContains("Timed out fetching quota") else {
            throw IntegrationError.unavailable("This Devin account is signed in, but its CLI could not fetch quota. The last successful reading is preserved.")
        }
        // The CLI has no JSON auth-status flag. Only explicitly labeled remaining
        // percentages or a consumed/limit ACU pair count as evidence. Unknown
        // output fails closed instead of inventing a full balance.
        var windows: [QuotaWindow] = []
        for (label, duration) in [("Daily", 1440), ("Weekly", 10080)] {
            let pattern = "(?im)^\\s*" + label + "(?: quota)?\\s*:?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*%\\s*(?:remaining|left)\\b"
            if let value = captures(pattern, text).first.flatMap(Double.init) {
                guard value.isFinite, (0...100).contains(value) else { throw IntegrationError.invalidResponse("Devin reported an invalid remaining quota.") }
                windows.append(QuotaWindow(label: label, usedPercent: 100 - value, resetsAt: nil, durationMinutes: duration))
            }
        }
        let acu = captures("(?im)([0-9]+(?:\\.[0-9]+)?)\\s*(?:/|of)\\s*([0-9]+(?:\\.[0-9]+)?)\\s*ACUs\\b", text)
        if acu.count == 2, let used = Double(acu[0]), let limit = Double(acu[1]), used.isFinite, used >= 0, limit.isFinite, limit > 0 {
            windows.append(QuotaWindow(label: "Billing cycle", usedPercent: used / limit * 100, resetsAt: nil, durationMinutes: nil))
        }
        guard !windows.isEmpty else {
            throw IntegrationError.unavailable("This Devin account is signed in, but the CLI did not report a readable account limit. Unreported limits stay unknown.")
        }
        let plan = captures("(?im)^\\s*Plan:\\s*(.+)$", text).first
        return UsageSource(id: configuration.id, integration: .devin, account: configuration.label, observedAt: now,
            payload: .quota(QuotaUsage(windows: windows, plan: plan)), origin: .live,
            notes: ["Read from this connection's private Devin CLI profile. No model run is started; unreported reset times remain unknown."], accountIdentity: email ?? configuration.accountIdentity)
    }

    private static func captures(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

@available(macOS 14.0, *)
struct DevinIntegration: UsageIntegration {
    let id = IntegrationID.devin
    func fetchSources() async throws -> [UsageSource] {
        try await DemoData.response([UsageSource(id: "devin-personal", integration: .devin, account: "Personal", observedAt: .now,
            payload: .quota(QuotaUsage(windows: [
                QuotaWindow(label: "Daily", usedPercent: 31, resetsAt: DemoData.later(8), durationMinutes: 1440),
                QuotaWindow(label: "Weekly", usedPercent: 44, resetsAt: DemoData.later(72), durationMinutes: 10080)
            ], plan: "Demo")))])
    }
}
