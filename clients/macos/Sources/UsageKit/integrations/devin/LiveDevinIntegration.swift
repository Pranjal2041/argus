import Foundation

/// Read-only CLI boundary: the installed CLI owns credentials and enterprise
/// routing. Never send a prompt, create a session, or scrape its credential store.
@available(macOS 14.0, *)
struct LiveDevinIntegration: UsageIntegration {
    let id = IntegrationID.devin
    let configuration: SourceConfiguration
    let executable: String
    var runner: any CommandRunning = CommandRunner()
    var descriptor: IntegrationDescriptor? { configuration.descriptor }

    func fetchSources() async throws -> [UsageSource] {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw IntegrationError.configuration("Install Devin CLI, then run devin auth login. Its signed-in account supplies this connection.")
        }
        let result = try await runner.run(executable: executable, arguments: ["auth", "status"],
            environment: ["NO_COLOR": "1"], timeout: 30)
        guard result.status == 0 else {
            throw IntegrationError.authentication("Devin CLI could not check this account. Run devin auth status, then sign in if needed.")
        }
        return [try Self.normalize(String(decoding: result.stdout + result.stderr, as: UTF8.self), configuration: configuration, now: .now)]
    }

    static func normalize(_ text: String, configuration: SourceConfiguration, now: Date) throws -> UsageSource {
        guard text.localizedCaseInsensitiveContains("Logged in") && !text.localizedCaseInsensitiveContains("Not logged in") else {
            throw IntegrationError.authentication("Sign in with devin auth login, then check this connection again.")
        }
        guard !text.localizedCaseInsensitiveContains("Failed to fetch quota"),
              !text.localizedCaseInsensitiveContains("No quota data"), !text.localizedCaseInsensitiveContains("Timed out fetching quota") else {
            throw IntegrationError.unavailable("Devin is signed in, but its CLI could not fetch account quota. Check devin auth status; the last successful reading is preserved.")
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
            throw IntegrationError.unavailable("Devin CLI did not report a readable account limit. Check devin auth status or your organization's usage page. Unreported limits stay unknown.")
        }
        let plan = captures("(?im)^\\s*Plan:\\s*(.+)$", text).first
        let email = captures("(?im)^\\s*Email:\\s*(\\S+)$", text).first
        return UsageSource(id: configuration.id, integration: .devin, account: configuration.label, observedAt: now,
            payload: .quota(QuotaUsage(windows: windows, plan: plan)), origin: .live,
            notes: ["Read from devin auth status. This connection follows the account signed into the local CLI. No model run is started; unreported reset times remain unknown."], accountIdentity: email)
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
