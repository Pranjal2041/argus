import Foundation

/// API-key-compatible spending telemetry. Wallet authentication is deliberately unrelated.
@available(macOS 14.0, *)
struct DaytonaAnalytics: Sendable {
    var client: any HTTPClient

    func fetch(organization: String, headers: [String: String], now: Date) async throws -> DaytonaAnalyticsReading {
        guard !organization.isEmpty, organization.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw IntegrationError.invalidResponse("Invalid Daytona analytics organization identity.")
        }
        var headers = headers
        headers["X-Daytona-Organization-ID"] = organization
        let from = UsageCalendar.monthStart(now)
        let formatter = ISO8601DateFormatter()
        func read(_ endpoint: String) async throws -> JSONValue {
            var url = URLComponents(string: "https://analytics.app.daytona.io/organization/\(organization)/usage/\(endpoint)")!
            url.queryItems = [URLQueryItem(name: "from", value: formatter.string(from: from)), URLQueryItem(name: "to", value: formatter.string(from: now))]
            return try await client.get(url.url!, headers: headers)
        }
        var aggregate: JSONValue?, aggregateError: (any Error)?
        do { aggregate = try await read("aggregated") }
        catch is CancellationError { throw CancellationError() }
        catch { aggregateError = error }
        var rows: [SpendBreakdown] = [], detailAvailable = false
        do { rows = try Self.sandboxes(try await read("sandbox")); detailAvailable = true }
        catch is CancellationError { throw CancellationError() }
        catch { if aggregate == nil { throw aggregateError ?? error } }
        let spent: Double
        if let aggregate {
            guard let total = aggregate["totalPrice"].double, total.isFinite, total >= 0 else {
                throw IntegrationError.invalidResponse("Daytona analytics did not report valid spending.")
            }
            spent = total
        } else { spent = rows.reduce(0) { $0 + $1.spent } }
        var notes: [String] = []
        if aggregate == nil { notes.append("Month-to-date spending is the sum of the provider's sandbox usage records; the aggregate endpoint was unavailable.") }
        if !detailAvailable { notes.append("Sandbox spending details could not be refreshed.") }
        if detailAvailable && abs(rows.reduce(0) { $0 + $1.spent } - spent) > max(0.01, spent * 0.0001) {
            notes.append("The aggregate total and sandbox breakdown were sampled separately and have not yet reconciled.")
        }
        var reading = DaytonaAnalyticsReading(spentUSD: spent, sandboxCount: aggregate?["sandboxCount"].int ?? (detailAvailable ? rows.count : nil),
            breakdown: rows, through: aggregate?["lastEnd"].date, notes: notes)
        do {
            let chart = try Self.chart(try await read("chart"), from: from, to: now)
            reading.dailySpend = chart.map(\.value); reading.dates = chart.map(\.date)
        } catch is CancellationError { throw CancellationError() }
        catch { reading.notes.append("The spending total is current, but the resource chart could not be refreshed.") }
        return reading
    }

    static func sandboxes(_ value: JSONValue) throws -> [SpendBreakdown] {
        guard let rows = value.array else { throw IntegrationError.invalidResponse("Daytona returned invalid sandbox spending.") }
        var seen = Set<String>()
        return try rows.compactMap { row in
            guard let id = row["sandboxId"].string, !id.isEmpty, let price = row["totalPrice"].double, price.isFinite, price >= 0 else {
                throw IntegrationError.invalidResponse("Daytona returned an invalid sandbox charge.")
            }
            guard seen.insert(id).inserted else { return nil }
            // Analytics prices are USD, unlike the wallet's explicit *Cents fields.
            return SpendBreakdown(name: id, spent: price)
        }.sorted { $0.spent > $1.spent }
    }

    static func chart(_ value: JSONValue, from: Date, to: Date) throws -> [(date: Date, value: Double)] {
        guard let rows = value.array else { throw IntegrationError.invalidResponse("Daytona returned an invalid resource chart.") }
        var days: [Date: Double] = [:], seen = Set<Date>()
        for row in rows {
            guard let time = row["time"].date else { throw IntegrationError.invalidResponse("Daytona returned an invalid chart timestamp.") }
            guard time >= from, time <= to, seen.insert(time).inserted else { continue }
            let amounts = ["cpuPrice", "ramPrice", "diskPrice"].compactMap { row[$0].double }
            guard amounts.count == 3, amounts.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw IntegrationError.invalidResponse("Daytona returned invalid resource chart prices.")
            }
            days[UsageCalendar.utc.startOfDay(for: time), default: 0] += amounts.reduce(0, +)
        }
        return days.sorted { $0.key < $1.key }.map { (date: $0.key, value: $0.value) }
    }
}

@available(macOS 14.0, *)
struct DaytonaAnalyticsReading: Sendable {
    var spentUSD: Double
    var sandboxCount: Int?
    var breakdown: [SpendBreakdown]
    var through: Date?
    var notes: [String]
    var dailySpend: [Double] = []
    var dates: [Date] = []
}
