import Foundation

@available(macOS 14.0, *)
struct MacStorageIntegration: UsageIntegration {
    let id = IntegrationID.macStorage

    func fetchSources() async throws -> [UsageSource] {
        try await DemoData.response([
            UsageSource(id: "macbook-pro", integration: id, account: "MacBook Pro", observedAt: .now,
                payload: .storage(StorageUsage(online: true, drives: [
                    StorageDrive(id: "macintosh-hd", name: "Macintosh HD", usedGB: 640, capacityGB: 1000,
                        breakdown: [
                            StorageBreakdown(name: "Projects", sizeGB: 284),
                            StorageBreakdown(name: "Applications", sizeGB: 142),
                            StorageBreakdown(name: "Documents & media", sizeGB: 126),
                            StorageBreakdown(name: "System & other", sizeGB: 88),
                        ], historyGB: [586, 595, 608, 621, 625, 632, 640])
                ])))
        ])
    }
}
