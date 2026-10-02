import Foundation

@available(macOS 14.0, *)
struct OpenAIIntegration: UsageIntegration {
    let id = IntegrationID.openaiAPI

    func fetchSources() async throws -> [UsageSource] {
        try await DemoData.response([
            UsageSource(id: "openai-personal", integration: id, account: "Personal", observedAt: .now,
                payload: .spend(SpendUsage(spent: 64.2, budget: 100, today: 3.42,
                    dailySpend: [4.2, 6.1, 5.8, 7.4, 3.6, 8.2, 4.9, 6.8, 5.3, 8.48, 3.42],
                    breakdown: [
                        SpendBreakdown(name: "Coding", requests: 1248, tokens: 2_840_000, spent: 38.4),
                        SpendBreakdown(name: "Research", requests: 684, tokens: 1_460_000, spent: 18.6),
                        SpendBreakdown(name: "Embeddings", requests: 8912, tokens: 4_200_000, spent: 7.2),
                    ])))
        ])
    }
}
