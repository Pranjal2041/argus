import Foundation

@available(macOS 14.0, *)
struct ClaudeIntegration: UsageIntegration {
    let id = IntegrationID.claude
    func fetchSources() async throws -> [UsageSource] {
        try await DemoData.response((0..<10).map { index in
            UsageSource(id: "claude-demo-\(index)", integration: .claude, account: ["Personal", "Research", "Work", "Team", "Lab", "Projects", "Claude 7", "Claude 8", "Claude 9", "Claude 10"][index], observedAt: DemoData.ago(1),
                payload: .quota(QuotaUsage(windows: [
                    QuotaWindow(label: "5-hour", usedPercent: Double(index * 13 % 100), resetsAt: DemoData.later(2), durationMinutes: 300),
                    QuotaWindow(label: "Weekly", usedPercent: Double(index * 18 % 100), resetsAt: DemoData.later(54), durationMinutes: 10080),
                ], additionalBuckets: [QuotaBucket(id: "seven_day_sonnet", name: "Sonnet", windows: [
                    QuotaWindow(label: "Weekly", usedPercent: 35, resetsAt: DemoData.later(54), durationMinutes: 10080),
                ])], plan: "Max")))
        })
    }
}
