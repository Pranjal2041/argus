import Foundation

@available(macOS 14.0, *)
struct ModalIntegration: UsageIntegration {
    let id = IntegrationID.modal

    func fetchSources() async throws -> [UsageSource] {
        let personal = [
            ComputeResource(id: "embedding-index", name: "embedding-index", state: .running, kind: "CPU", startedAt: DemoData.ago(134), hourlyRate: 0.06, cpu: 2, memoryGiB: 4),
            ComputeResource(id: "image-worker", name: "image-worker", state: .running, kind: "GPU", startedAt: DemoData.ago(24), hourlyRate: 0.12, cpu: 4, memoryGiB: 16),
        ]
        let work = ["batch-inference", "document-parser", "training-worker", "evaluation"].enumerated().map { index, name in
            ComputeResource(id: name, name: name, state: .running, kind: index % 2 == 0 ? "GPU" : "CPU", startedAt: DemoData.ago(Double(32 + index * 41)), hourlyRate: [0.32, 0.08, 0.48, 0.06][index], cpu: 4, memoryGiB: 16)
        }
        return try await DemoData.response([
            UsageSource(id: "modal-personal", integration: id, account: "Personal", observedAt: .now, payload: .compute(ComputeUsage(resources: personal, spent: 18, budget: 50, dailySpend: [0.8, 1.4, 0.9, 2.2, 1.2, 1.6, 1.1]))),
            UsageSource(id: "modal-work", integration: id, account: "Work", observedAt: .now, payload: .compute(ComputeUsage(resources: work, spent: 126, budget: 200, dailySpend: [5.2, 8.1, 6.8, 10.4, 7.1, 9.8, 8.6]))),
        ])
    }
}
