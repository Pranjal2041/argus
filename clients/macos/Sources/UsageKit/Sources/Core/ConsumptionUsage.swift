import Foundation

/// A measured amount is useful without a capacity, percentage, or reset time.
/// These readings stay account-scoped and never imply a remaining allowance.
@available(macOS 14.0, *)
struct ConsumptionUsage: Codable, Sendable {
    var used: Double
    var unit: String
    var period: ConsumptionPeriod?
    var plan: String?

    var hasReading: Bool { used.isFinite && used >= 0 && !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var formattedAmount: String { UsageFormat.number(used) }
    var usedLabel: String { "\(unit) used" }
}

/// Provider reporting interval [start, end), not a promise that a quota resets.
@available(macOS 14.0, *)
struct ConsumptionPeriod: Codable, Sendable {
    var start: Date
    var end: Date
    var timeZoneOffsetSeconds: Int = 0

    var label: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: timeZoneOffsetSeconds) ?? TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let last = end.addingTimeInterval(-0.001)
        formatter.dateFormat = calendar.component(.year, from: start) == calendar.component(.year, from: last) ? "MMM d" : "MMM d, yyyy"
        return "\(formatter.string(from: start)) – \(formatter.string(from: last))"
    }
}
