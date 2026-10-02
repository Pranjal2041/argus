import Foundation

/// Compact presentation uses the same readings as the full dashboard. Missing
/// billing and cached quota are never silently counted as zero.
@available(macOS 14.0, *)
struct CompactSummary {
    var sources: [UsageSource]

    var uniqueSources: [UsageSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }
    var overview: UsageOverview { UsageOverview(sources: uniqueSources) }
    var statusSources: [UsageSource] {
        let quotaIDs = Set(overview.quotaProviders.flatMap { overview.quotaAccounts($0).map(\.id) })
        let readingIDs = Set(providerReadings.map(\.id) + devices.map(\.id) + overview.consumptionSources.map(\.id))
        return uniqueSources.filter { !quotaIDs.contains($0.id) && !readingIDs.contains($0.id) }
    }
    var weeklyQuota: QuotaAggregate? {
        weeklyQuota(for: .codex)
    }
    var claudeWeeklyQuota: QuotaAggregate? { weeklyQuota(for: .claude) }
    var claudeAccounts: [UsageSource] { uniqueSources.filter { $0.integration == .claude } }

    private func weeklyQuota(for integration: IntegrationID) -> QuotaAggregate? {
        let readings = QuotaAggregate.mainReadings(sources: uniqueSources, integration: integration)
        return readings.first { $0.durationMinutes == 10080 }
            ?? readings.first { $0.durationMinutes == nil && $0.label.lowercased() == "weekly" }
    }
    var codexAccounts: [UsageSource] {
        uniqueSources.filter { !$0.isStale && $0.integration == .codex && $0.quota?.weeklyWindow?.usedPercent.isFinite == true }
    }
    /// Never combine billing accounts or unrelated resource types. Every value
    /// retains its provider/account identity all the way into the compact UI.
    var providerReadings: [CompactProviderReading] {
        uniqueSources.compactMap { source in
            guard !source.isStale else { return nil }
            let amount = source.compute?.spent ?? source.spend?.spent
            let spent = amount.flatMap { $0.isFinite ? $0 : nil }
            let running = source.compute?.resources.count
            guard spent != nil || running != nil else { return nil }
            let noun = source.integration == .daytona ? "sandboxes" : (source.integration == .modal ? "containers" : source.compute?.resourceNoun)
            return CompactProviderReading(id: source.id, integration: source.integration, account: source.account,
                                          spentUSD: spent, runningCount: running, resourceNoun: noun)
        }
    }
    var devices: [UsageSource] {
        uniqueSources.filter { !($0.storage?.drives.isEmpty ?? true) }
    }
    static func storageDrives(_ storage: StorageUsage) -> [StorageDrive] {
        // APFS volumes can share a container, and Windows may include virtual
        // cloud mounts. Keep capacities separate rather than inventing a pool.
        var seen = Set<String>()
        return storage.drives.filter { seen.insert($0.id).inserted }
    }
}

@available(macOS 14.0, *)
struct CompactProviderReading: Identifiable {
    var id: String
    var integration: IntegrationID
    var account: String
    var spentUSD: Double?
    var runningCount: Int?
    var resourceNoun: String?
}
