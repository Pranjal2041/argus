import Foundation

@available(macOS 14.0, *)
enum SourceCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case cloud, ai, devices
    var id: String { rawValue }
    var title: String {
        switch self { case .cloud: "Cloud"; case .ai: "AI"; case .devices: "Devices" }
    }
    var symbol: String {
        switch self { case .cloud: "cloud"; case .ai: "sparkles"; case .devices: "desktopcomputer" }
    }
}

@available(macOS 14.0, *)
enum IntegrationID: String, CaseIterable, Codable, Sendable, Identifiable {
    case daytona, modal, openaiAPI = "openai-api", codex, claude, devin
    case macStorage = "mac-storage", windowsStorage = "windows-storage"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .daytona: "Daytona"
        case .modal: "Modal"
        case .openaiAPI: "OpenAI API"
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .devin: "Devin CLI"
        case .macStorage: "macOS storage"
        case .windowsStorage: "Windows storage"
        }
    }
    var category: SourceCategory {
        switch self {
        case .daytona, .modal: .cloud
        case .openaiAPI, .codex, .claude, .devin: .ai
        case .macStorage, .windowsStorage: .devices
        }
    }
    var symbol: String {
        switch self {
        case .daytona: "shippingbox.fill"
        case .modal: "waveform.path"
        case .openaiAPI: "circle.hexagongrid.fill"
        case .codex: "square.stack.3d.up.fill"
        case .claude: "asterisk"
        case .devin: "terminal.fill"
        case .macStorage: "apple.logo"
        case .windowsStorage: "square.split.2x2.fill"
        }
    }
    var detail: String {
        switch self {
        case .daytona: "Sandboxes, capacity, and running costs"
        case .modal: "Running jobs and account budgets"
        case .openaiAPI: "API spending and project breakdowns"
        case .codex: "Account limits and reset windows"
        case .claude: "Five-hour, weekly, and model limits"
        case .devin: "Quota from your signed-in Devin CLI account"
        case .macStorage: "Drive capacity and storage on your Mac"
        case .windowsStorage: "Available space across Windows drives"
        }
    }
}

@available(macOS 14.0, *)
struct UsageSource: Identifiable, Codable, Sendable {
    var id: String
    var integration: IntegrationID
    var account: String
    var observedAt: Date
    var payload: UsagePayload
    var origin: SourceOrigin = .demo
    var notes: [String] = []
    var isStale = false
    var accountIdentity: String?
    var capabilities: [SourceCapability]?
    var hasLimitedAccess: Bool { capabilities?.contains { $0.status != .available && $0.isOptional != true } == true }
    var hasUnavailableCapabilities: Bool { capabilities?.contains { $0.status != .available } == true }
    var category: SourceCategory { integration.category }
    var name: String { integration.name }
    var compute: ComputeUsage? { if case .compute(let value) = payload { value } else { nil } }
    var spend: SpendUsage? { if case .spend(let value) = payload { value } else { nil } }
    var quota: QuotaUsage? { if case .quota(let value) = payload { value } else { nil } }
    var storage: StorageUsage? { if case .storage(let value) = payload { value } else { nil } }
    var unavailable: UnavailableUsage? { if case .unavailable(let value) = payload { value } else { nil } }
    var hasOverviewReading: Bool {
        compute != nil || spend != nil || quota?.allWindows.isEmpty == false || storage?.drives.isEmpty == false
    }
}

@available(macOS 14.0, *)
struct SourceCapability: Identifiable, Codable, Sendable {
    enum Status: String, Codable, Sendable { case available, accessRequired, unavailable }
    var id: String
    var label: String
    var status: Status
    var message: String
    var isOptional: Bool?
    var shortStatus: String {
        switch status { case .available: "Connected"; case .accessRequired: "Access needed"; case .unavailable: "Unavailable" }
    }
}

@available(macOS 14.0, *)
enum SourceOrigin: String, Codable, Sendable { case demo, live }

@available(macOS 14.0, *)
struct UnavailableUsage: Codable, Sendable {
    var title: String
    var message: String
    var needsAuthentication = false
}

@available(macOS 14.0, *)
enum UsagePayload: Codable, Sendable {
    case compute(ComputeUsage)
    case spend(SpendUsage)
    case quota(QuotaUsage)
    case storage(StorageUsage)
    case unavailable(UnavailableUsage)
}

@available(macOS 14.0, *)
struct ComputeUsage: Codable, Sendable {
    var resources: [ComputeResource]
    var capacity: ComputeCapacity?
    var spent: Double?
    var budget: Double?
    var dailySpend: [Double]
    var dailySpendDates: [Date] = []
    var spendingThrough: Date?
    var resourceNoun = "sandboxes"
    var idleDetectionAvailable = true
    var ratesAvailable = true
    var billingBreakdown: [SpendBreakdown] = []
    var providerCapacity: [CapacityReading] = []
    var accountBalanceUSD: Double?
    var inventoryCounts: [String: Int]?
    var periodSandboxCount: Int?
    var spendChartTitle: String?
    var spendChartNote: String?
    var spendBreakdownTitle: String?
    var hourlyRate: Double? {
        guard ratesAvailable, resources.allSatisfy({ $0.hourlyRate != nil }) else { return nil }
        return resources.reduce(0) { $0 + ($1.hourlyRate ?? 0) }
    }
    var idle: [ComputeResource] { resources.filter { $0.state == .idle } }
    var allocatedCPU: Double? {
        guard resources.allSatisfy({ $0.cpu != nil }) else { return nil }
        return resources.reduce(0) { $0 + ($1.cpu ?? 0) }
    }
    var allocatedMemory: Double? {
        guard resources.allSatisfy({ $0.memoryGiB != nil }) else { return nil }
        return resources.reduce(0) { $0 + ($1.memoryGiB ?? 0) }
    }
}

@available(macOS 14.0, *)
struct CapacityReading: Identifiable, Codable, Sendable {
    var id: String
    var label: String
    var used: Double
    var limit: Double
    var unit: String
}

@available(macOS 14.0, *)
struct ComputeCapacity: Codable, Sendable {
    var sandboxes: Int?
    var cpu: Double?
    var memoryGiB: Double?
}

@available(macOS 14.0, *)
struct ComputeResource: Identifiable, Codable, Sendable {
    enum State: String, Codable, Sendable { case running, idle }
    var id: String
    var name: String
    var state: State
    var kind: String
    var startedAt: Date?
    var hourlyRate: Double?
    var cpu: Double?
    var memoryGiB: Double?
}

@available(macOS 14.0, *)
struct SpendUsage: Codable, Sendable {
    var spent: Double
    var budget: Double?
    var today: Double
    var dailySpend: [Double]
    var breakdown: [SpendBreakdown]
    var dailySpendDates: [Date] = []
    var spendingThrough: Date?
}

@available(macOS 14.0, *)
struct SpendBreakdown: Identifiable, Codable, Sendable {
    var id: String { name }
    var name: String
    var requests: Int?
    var tokens: Int?
    var spent: Double
}

@available(macOS 14.0, *)
struct QuotaUsage: Codable, Sendable {
    var windows: [QuotaWindow]
    var weeklyHistory: [Double]
    var additionalBuckets: [QuotaBucket] = []
    var plan: String?
    var credits: String?
    var resetCreditsAvailable: Int?
    var allWindows: [QuotaWindow] { windows + additionalBuckets.flatMap(\.windows) }
    var mostUsedWindow: QuotaWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
    var shortWindow: QuotaWindow? { windows.first { ($0.durationMinutes ?? 0) < 10080 && $0.label != "Weekly" } }
    var weeklyWindow: QuotaWindow? { windows.first { $0.durationMinutes == 10080 || $0.label == "Weekly" } }

    init(windows: [QuotaWindow], weeklyHistory: [Double] = [], additionalBuckets: [QuotaBucket] = [], plan: String? = nil, credits: String? = nil, resetCreditsAvailable: Int? = nil) {
        self.windows = windows; self.weeklyHistory = weeklyHistory; self.additionalBuckets = additionalBuckets
        self.plan = plan; self.credits = credits; self.resetCreditsAvailable = resetCreditsAvailable
    }
    init(shortWindow: QuotaWindow, weeklyWindow: QuotaWindow, weeklyHistory: [Double]) {
        self.init(windows: [shortWindow, weeklyWindow], weeklyHistory: weeklyHistory)
    }
}

@available(macOS 14.0, *)
struct QuotaBucket: Identifiable, Codable, Sendable {
    var id: String
    var name: String
    var windows: [QuotaWindow]
}

@available(macOS 14.0, *)
struct QuotaWindow: Identifiable, Codable, Sendable {
    var id: String { label + "-\(durationMinutes ?? 0)" }
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var durationMinutes: Int?
    var remainingPercent: Double { usedPercent.isFinite ? min(100, max(0, 100 - usedPercent)) : 0 }
}

/// Equal-weight averages of matching windows, never a pooled token allowance.
/// Cached/unavailable sources are excluded, and coverage remains visible.
@available(macOS 14.0, *)
struct QuotaAggregate: Identifiable, Sendable {
    var id: String
    var bucketName: String
    var label: String
    var durationMinutes: Int?
    var remainingPercent: Double
    var accountCount: Int
    var totalAccounts: Int

    static func mainReadings(sources: [UsageSource], integration: IntegrationID = .codex) -> [QuotaAggregate] {
        readings(sources: sources, integration: integration).filter { $0.id.hasPrefix("main:") }
    }

    static func readings(sources: [UsageSource], integration: IntegrationID = .codex) -> [QuotaAggregate] {
        let accounts = Dictionary(sources.filter { $0.integration == integration }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        var groups: [String: QuotaAggregate] = [:]
        for source in accounts where !source.isStale {
            guard let quota = source.quota else { continue }
            let buckets = [QuotaBucket(id: "main", name: integration.name, windows: quota.windows)] + quota.additionalBuckets
            var seen = Set<String>()
            for bucket in buckets {
                for window in bucket.windows where window.usedPercent.isFinite {
                    let windowKey = window.durationMinutes.map(String.init) ?? "label:\(window.label)"
                    let key = bucket.id + ":" + windowKey
                    guard seen.insert(key).inserted else { continue }
                    var value = groups[key] ?? QuotaAggregate(id: key, bucketName: bucket.name, label: window.label,
                        durationMinutes: window.durationMinutes, remainingPercent: 0, accountCount: 0, totalAccounts: accounts.count)
                    value.remainingPercent += window.remainingPercent
                    value.accountCount += 1
                    groups[key] = value
                }
            }
        }
        return groups.values.map { value in
            var result = value; result.remainingPercent /= Double(value.accountCount); return result
        }.sorted {
            if $0.id.hasPrefix("main:") != $1.id.hasPrefix("main:") { return $0.id.hasPrefix("main:") }
            if $0.bucketName != $1.bucketName { return $0.bucketName < $1.bucketName }
            return ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0)
        }
    }
}

@available(macOS 14.0, *)
struct StorageUsage: Codable, Sendable {
    var online: Bool
    var drives: [StorageDrive]
}

@available(macOS 14.0, *)
struct StorageDrive: Identifiable, Codable, Sendable {
    var id: String
    var name: String
    var usedGB: Double
    var capacityGB: Double
    var breakdown: [StorageBreakdown]
    var historyGB: [Double]
    var freeGB: Double { max(0, capacityGB - usedGB) }
    var usedPercent: Double { capacityGB > 0 ? usedGB / capacityGB * 100 : 0 }
}

@available(macOS 14.0, *)
struct StorageBreakdown: Identifiable, Codable, Sendable {
    var id: String { name }
    var name: String
    var sizeGB: Double
}

@available(macOS 14.0, *)
struct AddedSource: Identifiable, Codable, Sendable {
    var id: String
    var integration: IntegrationID
    var label: String
}

@available(macOS 14.0, *)
struct DetailSelection: Equatable, Identifiable {
    var sourceID: String
    var driveID: String?
    var id: String { sourceID + (driveID ?? "") }
}

@available(macOS 14.0, *)
struct AttentionItem: Identifiable {
    var id: String
    var title: String
    var detail: String
    var selection: DetailSelection
    var category: SourceCategory
}

@available(macOS 14.0, *)
struct ActivityEvent: Identifiable {
    var id = UUID()
    var title: String
    var detail: String
    var date: Date
    var symbol: String
    var category: SourceCategory?
    var isWarning = false
    var selection: DetailSelection?
}
