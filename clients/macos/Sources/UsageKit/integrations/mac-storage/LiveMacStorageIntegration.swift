import Foundation

@available(macOS 14.0, *)
struct LiveMacStorageIntegration: UsageIntegration {
    let id = IntegrationID.macStorage
    let configuration: SourceConfiguration
    var descriptor: IntegrationDescriptor? { configuration.descriptor }

    func fetchSources() async throws -> [UsageSource] {
        let configured = configuration.mountPaths ?? [FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"]
        var drives: [StorageDrive] = []
        var seen = Set<String>()
        for path in configured {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let values = try url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let identity = values.volumeUUIDString ?? path
            guard seen.insert(identity).inserted else { continue }
            guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity, total > 0, free >= 0, free <= total else {
                throw IntegrationError.invalidResponse("macOS did not report valid volume capacity.")
            }
            drives.append(StorageDrive(id: identity, name: path == "/System/Volumes/Data" ? "Macintosh HD" : (values.volumeName ?? url.lastPathComponent),
                                       usedGB: Double(total - free) / 1e9, capacityGB: Double(total) / 1e9, breakdown: [], historyGB: []))
        }
        guard !drives.isEmpty else { throw IntegrationError.unavailable("No configured local volumes are available.") }
        return [UsageSource(id: configuration.id, integration: .macStorage, account: configuration.label, observedAt: .now,
                            payload: .storage(StorageUsage(online: true, drives: drives)), origin: .live,
                            notes: ["Read-only macOS volume capacity. APFS volumes share container space; system/data volumes are not added together. Available space excludes reclaimable estimates. No folders are scanned."])]
    }
}
