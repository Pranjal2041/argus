import Foundation

@available(macOS 14.0, *)
struct DaytonaIntegration: UsageIntegration {
    let id = IntegrationID.daytona

    func fetchSources() async throws -> [UsageSource] {
        let rows: [(String, Double, Double, Int, Int, ComputeResource.State)] = [
            ("api-dev", 192, 0.06, 2, 4, .running),
            ("agent-run-12", 108, 0.06, 2, 4, .running),
            ("tests", 42, 0.05, 2, 4, .running),
            ("preview", 126, 0.04, 2, 4, .running),
            ("playground", 380, 0.04, 2, 4, .idle),
            ("eval-run", 70, 0.03, 2, 4, .running),
            ("scraper", 34, 0.03, 1, 2, .running),
            ("branch-old", 290, 0.03, 1, 2, .idle),
        ]
        let resources = rows.map { name, minutes, rate, cpu, memory, state in
            ComputeResource(id: "sb-\(name)", name: name, state: state, kind: "Sandbox", startedAt: DemoData.ago(minutes), hourlyRate: rate, cpu: Double(cpu), memoryGiB: Double(memory))
        }
        return try await DemoData.response([
            UsageSource(id: "daytona-personal", integration: id, account: "Personal", observedAt: .now,
                payload: .compute(ComputeUsage(resources: resources, capacity: ComputeCapacity(sandboxes: 20, cpu: 40, memoryGiB: 80), spent: 42.8, dailySpend: [1.8, 2.3, 2.3, 4.1, 2.4, 1.8, 2.4])))
        ])
    }
}
