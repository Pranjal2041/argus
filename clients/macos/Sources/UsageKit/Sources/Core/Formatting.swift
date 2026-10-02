import Foundation

@available(macOS 14.0, *)
enum UsageFormat {
    static func money(_ value: Double, decimals: Bool = true) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(decimals ? 2 : 0)))
    }
    static func money(_ value: Double?, decimals: Bool = true) -> String {
        value.map { money($0, decimals: decimals) } ?? "—"
    }
    static func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...1))) ?? "—"
    }
    static func storage(_ gb: Double) -> String {
        if gb >= 1000 {
            return (gb / 1000).formatted(.number.precision(.fractionLength(0...2))) + " TB"
        }
        return gb.formatted(.number.precision(.fractionLength(0...1))) + " GB"
    }
    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "%"
    }
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(ceil(interval / 60)))
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        if days > 0 { return hours == 0 ? "\(days)d" : "\(days)d \(hours)h" }
        if hours > 0 { return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m" }
        return "\(remainder)m"
    }
    static func reset(_ date: Date, now: Date) -> String {
        date > now ? "Resets in \(duration(date.timeIntervalSince(now)))" : "Awaiting reset update"
    }
    static func reset(_ date: Date?, now: Date) -> String {
        date.map { reset($0, now: now) } ?? "Reset not reported"
    }
    static func freshness(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        return duration(interval) + " ago"
    }
    static var month: String { Date.now.formatted(.dateTime.month(.wide)) }
}
