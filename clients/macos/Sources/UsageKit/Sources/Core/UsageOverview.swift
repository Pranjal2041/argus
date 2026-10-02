import Foundation

/// Connection presence and measured usage are separate. Every source gets a
/// reading or a status presentation; missing readings never become zero usage.
@available(macOS 14.0, *)
struct UsageOverview {
    let sources: [UsageSource]

    init(sources: [UsageSource]) {
        var seen = Set<String>()
        self.sources = sources.filter { seen.insert($0.id).inserted }
    }

    var readingSources: [UsageSource] { sources.filter(\.hasOverviewReading) }
    var consumptionSources: [UsageSource] { sources.filter { $0.consumption?.hasReading == true } }
    var quotaProviders: [IntegrationID] {
        IntegrationID.allCases.filter { provider in
            sources.contains { $0.integration == provider && $0.quota?.allWindows.isEmpty == false }
        }
    }
    func quotaAccounts(_ provider: IntegrationID) -> [UsageSource] {
        sources.filter { $0.integration == provider && $0.consumption == nil }
    }
    var statusSources: [UsageSource] {
        let grouped = Set(quotaProviders.flatMap { quotaAccounts($0).map(\.id) })
        return sources.filter { !$0.hasOverviewReading && !grouped.contains($0.id) }
    }
}

@available(macOS 14.0, *)
extension UsageSource {
    var readingStatusTitle: String {
        if isStale { return "Cached usage" }
        if unavailable?.needsAuthentication == true { return "Sign-in required" }
        if let title = unavailable?.title, title != "Unavailable" { return title }
        return "Usage unavailable"
    }

    var connectionStatusTitle: String {
        if isStale { return "Cached" }
        if hasLimitedAccess { return "Limited access" }
        if let unavailable {
            return unavailable.needsAuthentication ? "Sign in" : unavailable.title
        }
        return hasOverviewReading ? "Connected" : "Unavailable"
    }
}
