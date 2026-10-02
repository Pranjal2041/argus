import Foundation

/// Alert decisions consume normalized measurements, never provider response formats.
/// Missing/stale readings do not trigger alerts or acknowledge an existing episode.
@available(macOS 14.0, *)
struct UsageAlertPolicy: Codable, Equatable {
    var enabled = true
    var quotaEnabled = true
    var budgetEnabled = true
    var storageEnabled = true
    var quotaRemaining = 10.0
    var budgetRemaining = 10.0
    var storageRemaining = 10.0
    var includeModelLimits = false
    var mutedSources: Set<String> = []
    var snoozeHours = 4.0

    func threshold(_ kind: UsageMeasurement.Kind) -> Double? {
        guard enabled else { return nil }
        let value: Double
        switch kind {
        case .quota: guard quotaEnabled else { return nil }; value = quotaRemaining
        case .budget: guard budgetEnabled else { return nil }; value = budgetRemaining
        case .storage: guard storageEnabled else { return nil }; value = storageRemaining
        }
        return value.isFinite ? min(100, max(0, value)) : nil
    }
}

@available(macOS 14.0, *)
public struct UsageWarning: Identifiable, Equatable {
    public let id: String
    public let sourceID: String
    public let title: String
    public let detail: String
    public let remaining: Double
    public let critical: Bool
    public let resetsAt: Date?
    let cycle: String
    let driveID: String?
}

@available(macOS 14.0, *)
struct UsageMeasurement {
    enum Kind { case quota, budget, storage }
    var id: String
    var sourceID: String
    var title: String
    var label: String
    var remaining: Double
    var kind: Kind
    var cycle: String
    var resetsAt: Date?
    var driveID: String?

    static func readings(_ sources: [UsageSource], now: Date, maxAge: TimeInterval, includeModelLimits: Bool) -> [Self] {
        var output: [Self] = []
        for source in sources where !source.isStale && source.unavailable == nil &&
            now.timeIntervalSince(source.observedAt) <= maxAge && source.observedAt <= now.addingTimeInterval(60) {
            let title = "\(source.name) · \(source.account)"
            if let quota = source.quota {
                let buckets = [QuotaBucket(id: "main", name: "", windows: quota.windows)] + (includeModelLimits ? quota.additionalBuckets : [])
                for bucket in buckets {
                    for window in bucket.windows where window.usedPercent.isFinite && (window.resetsAt == nil || window.resetsAt! > now) {
                        let key = [source.id, "quota", bucket.id, window.id]
                        output.append(Self(id: identity(key), sourceID: source.id, title: title,
                            label: [bucket.name, window.label].filter { !$0.isEmpty }.joined(separator: " · "),
                            remaining: window.remainingPercent, kind: .quota,
                            cycle: window.resetsAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "unreported",
                            resetsAt: window.resetsAt))
                    }
                }
            }
            if let spent = source.compute?.spent ?? source.spend?.spent,
               let budget = source.compute?.budget ?? source.spend?.budget,
               spent.isFinite, spent >= 0, budget.isFinite, budget > 0,
               source.observedAt >= UsageCalendar.monthStart(now) {
                // Billing is normalized month-to-date in UTC by the adapters.
                let month = UsageCalendar.monthStart(now)
                output.append(Self(id: identity([source.id, "budget"]), sourceID: source.id, title: title,
                    label: "monthly budget", remaining: max(0, (1 - spent / budget) * 100), kind: .budget,
                    cycle: String(Int64(month.timeIntervalSince1970)),
                    resetsAt: UsageCalendar.utc.date(byAdding: .month, value: 1, to: month)))
            }
            if let storage = source.storage, storage.online {
                for drive in CompactSummary.storageDrives(storage) where drive.capacityGB.isFinite && drive.capacityGB > 0 && drive.freeGB.isFinite && drive.freeGB >= 0 {
                    output.append(Self(id: identity([source.id, "storage", drive.id]), sourceID: source.id,
                        title: title, label: drive.name + " space", remaining: min(100, drive.freeGB / drive.capacityGB * 100),
                        kind: .storage, cycle: "until-recovered", driveID: drive.id))
                }
            }
        }
        return output
    }

    static func identity(_ parts: [String]) -> String { parts.map { "\($0.utf8.count):\($0)" }.joined() }
}

@available(macOS 14.0, *)
struct UsageAlertEngine {
    struct Dismissal: Codable {
        var cycle: String
        var critical: Bool
        var expiresAt: Date?
    }
    var dismissals: [String: Dismissal] = [:]

    mutating func evaluate(_ measurements: [UsageMeasurement], policy: UsageAlertPolicy, now: Date) -> [UsageWarning] {
        var seen = Set<String>()
        var warnings: [UsageWarning] = []
        for metric in measurements where seen.insert(metric.id).inserted {
            guard let threshold = policy.threshold(metric.kind), metric.remaining.isFinite else { continue }
            if metric.remaining > threshold + 1e-9 {
                dismissals.removeValue(forKey: metric.id)
                continue
            }
            guard !policy.mutedSources.contains(metric.sourceID) else { continue }
            let critical = metric.remaining <= min(2, threshold / 4) + 1e-9
            if let dismissal = dismissals[metric.id], dismissal.cycle == metric.cycle,
               (dismissal.critical || !critical), dismissal.expiresAt.map({ $0 > now }) ?? true { continue }
            dismissals.removeValue(forKey: metric.id)
            warnings.append(UsageWarning(id: metric.id, sourceID: metric.sourceID, title: metric.title,
                detail: "\(UsageFormat.percent(metric.remaining)) \(metric.label.lowercased()) remaining",
                remaining: metric.remaining, critical: critical, resetsAt: metric.resetsAt,
                cycle: metric.cycle, driveID: metric.driveID))
        }
        return warnings.sorted { $0.remaining == $1.remaining ? $0.id < $1.id : $0.remaining < $1.remaining }
    }

    mutating func dismiss(_ warning: UsageWarning, until: Date? = nil) {
        dismissals[warning.id] = Dismissal(cycle: warning.cycle, critical: warning.critical, expiresAt: until)
    }
}
