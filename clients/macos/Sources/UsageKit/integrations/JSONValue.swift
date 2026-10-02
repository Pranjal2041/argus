import Foundation

/// A Sendable JSON tree for versioned CLI protocols and sparse provider responses.
@available(macOS 14.0, *)
enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var double: Double? {
        switch self { case .number(let value): value; case .string(let value): Double(value); default: nil }
    }
    var int: Int? { double.flatMap { $0.isFinite && $0 >= Double(Int.min) && $0 < Double(Int.max) ? Int($0) : nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var date: Date? {
        if case .number(let value) = self { return Date(timeIntervalSince1970: value) }
        guard let value = string else { return nil }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
    static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

@available(macOS 14.0, *)
enum UsageCalendar {
    static var utc: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    static func monthStart(_ date: Date) -> Date { utc.dateInterval(of: .month, for: date)!.start }
    static func hourStart(_ date: Date) -> Date { utc.dateInterval(of: .hour, for: date)!.start }
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func dailySeries(_ entries: [(Date, Double)], from start: Date, through end: Date) -> (dates: [Date], values: [Double]) {
        let calendar = utc
        let grouped = Dictionary(grouping: entries, by: { calendar.startOfDay(for: $0.0) })
        var date = calendar.startOfDay(for: start); var dates: [Date] = []; var values: [Double] = []
        while date <= end, dates.count < 366 {
            dates.append(date); values.append((grouped[date] ?? []).reduce(0) { $0 + $1.1 })
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return (dates, values)
    }
}
