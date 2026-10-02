import Foundation

@available(macOS 14.0, *)
struct WindowsStorageIntegration: UsageIntegration {
    let id = IntegrationID.windowsStorage

    func fetchSources() async throws -> [UsageSource] {
        try await DemoData.response([
            UsageSource(id: "windows-pc", integration: id, account: "Windows PC", observedAt: DemoData.ago(18),
                payload: .storage(StorageUsage(online: false, drives: [
                    StorageDrive(id: "c-system", name: "C: · System", usedGB: 820, capacityGB: 1000,
                        breakdown: [StorageBreakdown(name: "Applications", sizeGB: 356), StorageBreakdown(name: "System", sizeGB: 284), StorageBreakdown(name: "Documents", sizeGB: 180)], historyGB: [782, 792, 800, 804, 811, 816, 820]),
                    StorageDrive(id: "d-projects", name: "D: · Projects", usedGB: 1920, capacityGB: 2000,
                        breakdown: [StorageBreakdown(name: "Model checkpoints", sizeGB: 1120), StorageBreakdown(name: "Datasets", sizeGB: 486), StorageBreakdown(name: "Repositories", sizeGB: 214), StorageBreakdown(name: "Caches & other", sizeGB: 100)], historyGB: [1610, 1680, 1712, 1780, 1830, 1892, 1920]),
                    StorageDrive(id: "e-archive", name: "E: · Archive", usedGB: 1200, capacityGB: 4000,
                        breakdown: [StorageBreakdown(name: "Backups", sizeGB: 860), StorageBreakdown(name: "Media", sizeGB: 340)], historyGB: [1120, 1140, 1140, 1150, 1180, 1200, 1200]),
                ])))
        ])
    }
}
