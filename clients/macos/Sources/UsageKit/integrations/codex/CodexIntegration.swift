import Foundation

@available(macOS 14.0, *)
struct CodexIntegration: UsageIntegration {
    let id = IntegrationID.codex

    func fetchSources() async throws -> [UsageSource] {
        let accounts: [(String, Double, Double, Double, Double)] = [
            ("Personal", 34, 61, 2 + 10.0 / 60, 72),
            ("Work", 12, 43, 4 + 2.0 / 60, 120),
            ("Research", 76, 92, 38.0 / 60, 30),
            ("Experiments", 8, 24, 3.75, 96),
            ("Spare", 0, 5, 4 + 50.0 / 60, 144),
        ]
        return try await DemoData.response(accounts.map { account, short, weekly, shortHours, weekHours in
            UsageSource(id: "codex-\(account.lowercased())", integration: id, account: account, observedAt: .now,
                payload: .quota(QuotaUsage(
                    shortWindow: QuotaWindow(label: "5-hour", usedPercent: short, resetsAt: DemoData.later(shortHours)),
                    weeklyWindow: QuotaWindow(label: "Weekly", usedPercent: weekly, resetsAt: DemoData.later(weekHours)),
                    weeklyHistory: [0.08, 0.17, 0.34, 0.41, 0.62, 0.84, 1].map { ($0 * weekly).rounded() }
                )))
        })
    }
}
