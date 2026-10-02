import Charts
import SwiftUI

@available(macOS 14.0, *)
struct SpendDetailView: View {
    var source: UsageSource
    var spend: SpendUsage
    var now: Date

    var body: some View {
        DetailTitle(title: "API usage", subtitle: "\(UsageFormat.month) · \(source.origin == .live ? "UTC · " : "")Updated \(UsageFormat.freshness(source.observedAt, now: now))")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(UsageFormat.money(spend.spent)).font(.system(size: 36, weight: .semibold)).tracking(-0.8)
            if let budget = spend.budget {
                Text("/ \(UsageFormat.money(budget, decimals: false)) budget").font(.system(size: 14)).foregroundStyle(Palette.secondary)
            }
        }.monospacedDigit()
        if let budget = spend.budget, budget > 0 {
            VStack(spacing: 9) {
                UsageMeter(percent: spend.spent / budget * 100, height: 9)
                HStack {
                    Text("\(UsageFormat.percent(spend.spent / budget * 100)) used")
                    Spacer()
                    Text("\(UsageFormat.money(max(0, budget - spend.spent))) remaining")
                }.font(.system(size: 11)).foregroundStyle(Palette.secondary).monospacedDigit()
            }
        }
        HStack(spacing: 25) {
            SmallMetric(label: "Today\(source.origin == .live ? " · UTC" : "")", value: UsageFormat.money(spend.today))
            if !spend.breakdown.isEmpty, spend.breakdown.allSatisfy({ $0.requests != nil }) {
                SmallMetric(label: "Requests this month", value: spend.breakdown.compactMap(\.requests).reduce(0, +).formatted())
            }
        }
        if !spend.dailySpend.isEmpty {
            Hairline()
            SpendChart(values: spend.dailySpend, dates: spend.dailySpendDates)
        }
        if !spend.breakdown.isEmpty {
            Hairline()
            SpendingBreakdownView(title: "By project", rows: spend.breakdown, total: spend.spent)
        }
        if spend.budget != nil {
            InfoNote(text: "This is a budget you set, not a provider spending limit.")
        }
    }
}

@available(macOS 14.0, *)
struct SpendingBreakdownView: View {
    var title: String
    var rows: [SpendBreakdown]
    var total: Double
    @State private var showAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 14, weight: .semibold))
            ForEach(showAll ? rows : Array(rows.prefix(6))) { row in
                VStack(spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 5)
                        Text(UsageFormat.money(row.spent)).font(.system(size: 12, weight: .medium)).monospacedDigit().fixedSize()
                    }
                    if total > 0 { UsageMeter(percent: row.spent / total * 100, height: 5) }
                    if row.requests != nil || row.tokens != nil {
                        HStack {
                            if let requests = row.requests { Text("\(requests.formatted()) requests") }
                            Spacer()
                            if let tokens = row.tokens { Text("\(tokens.formatted()) tokens") }
                        }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }
                }.padding(.bottom, 5)
            }
            if rows.count > 6 {
                Button(showAll ? "Show top 6" : "Show all \(rows.count)") { showAll.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.blue)
            }
        }
    }
}

@available(macOS 14.0, *)
struct QuotaDetailView: View {
    var source: UsageSource
    var quota: QuotaUsage
    var now: Date
    var body: some View {
        DetailTitle(title: "Account limits", subtitle: source.accountIdentity ?? source.account)
        if let plan = quota.plan {
            HStack {
                SoftBadge(text: plan.capitalized)
                Spacer()
                if let available = quota.resetCreditsAvailable {
                    Text("\(available) reset\(available == 1 ? "" : "s") available").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
        }
        ForEach(quota.windows) { quotaBlock($0) }
        if !quota.additionalBuckets.isEmpty {
            DisclosureGroup("Other model limits") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(quota.additionalBuckets) { bucket in
                        Text(bucket.name).font(.system(size: 14, weight: .semibold))
                        ForEach(bucket.windows) { quotaBlock($0) }
                    }
                }.padding(.top, 14)
            }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        if !quota.weeklyHistory.isEmpty {
            Hairline()
            SampleHistoryChart(title: "Weekly remaining", values: quota.weeklyHistory.map { max(0, 100 - $0) }, upperBound: 100, isPercent: true)
        }
        if let credits = quota.credits {
            HStack {
                Text("Reported credit balance").foregroundStyle(Palette.secondary)
                Spacer()
                Text(credits).monospacedDigit()
            }.font(.system(size: 12))
        }
        InfoNote(text: "Limits belong to this account and model. Missing windows are not inferred. This app only reads usage; it never consumes resets, buys credits, or runs a model.")
    }

    private func quotaBlock(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(window.label) window").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(UsageFormat.percent(window.remainingPercent)) remaining").font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Palette.text).monospacedDigit()
            }
            UsageMeter(percent: window.remainingPercent, height: 8, meaning: "remaining")
            if let date = window.resetsAt {
                HStack {
                    Label(UsageFormat.reset(date, now: now), systemImage: "clock")
                    Spacer()
                    Text("Resets independently")
                }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            }
        }.padding(18).background(Palette.inset.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

@available(macOS 14.0, *)
struct StorageDetailView: View {
    var source: UsageSource
    var storage: StorageUsage
    @Binding var selectedDriveID: String?
    var now: Date
    private var drive: StorageDrive? { storage.drives.first { $0.id == selectedDriveID } ?? storage.drives.first }
    private let colors = [Palette.blue, Color(hex: 0x7FA8E9), Color(hex: 0x87B4B7), Color(hex: 0xB0BBCD)]

    var body: some View {
        DetailTitle(title: source.account, subtitle: storage.online ? "Live storage usage" : "Last seen \(UsageFormat.freshness(source.observedAt, now: now))")
        if storage.drives.count > 1 {
            Picker("Drive", selection: $selectedDriveID) {
                ForEach(storage.drives) { drive in Text(drive.name).tag(Optional(drive.id)) }
            }.labelsHidden().pickerStyle(.segmented).accessibilityIdentifier("drive-picker")
        }
        if let drive {
            VStack(alignment: .leading, spacing: 8) {
                Text(drive.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(UsageFormat.storage(drive.freeGB)).font(.system(size: 34, weight: .semibold)).tracking(-0.6)
                        .foregroundStyle(Palette.text)
                    Text("free").font(.system(size: 17)).foregroundStyle(Palette.secondary)
                    Spacer()
                    SoftBadge(text: drive.usedPercent >= 90 ? "Low space" : "Available", symbol: drive.usedPercent >= 90 ? "exclamationmark.triangle" : "checkmark", warning: drive.usedPercent >= 90)
                }.monospacedDigit()
            }
            VStack(spacing: 10) {
                UsageMeter(percent: drive.usedPercent, height: 10)
                HStack {
                    Text("\(UsageFormat.storage(drive.usedGB)) / \(UsageFormat.storage(drive.capacityGB)) used")
                    Spacer()
                    Text(UsageFormat.percent(drive.usedPercent))
                }.font(.system(size: 11)).foregroundStyle(Palette.secondary).monospacedDigit()
            }
            if !storage.online {
                InfoNote(text: "Showing the last successful reading from \(UsageFormat.freshness(source.observedAt, now: now)). Refreshing other sources does not change this timestamp.")
            }
            if !drive.breakdown.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: 19) {
                    Text("What's using space").font(.system(size: 14, weight: .semibold))
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            ForEach(Array(drive.breakdown.enumerated()), id: \.element.id) { index, segment in
                                Rectangle().fill(colors[index % colors.count])
                                    .frame(width: max(0, (geometry.size.width - CGFloat(drive.breakdown.count - 1) * 2) * segment.sizeGB / max(1, drive.usedGB)))
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 4))
                    }.frame(height: 14)
                    ForEach(Array(drive.breakdown.enumerated()), id: \.element.id) { index, segment in
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 2).fill(colors[index % colors.count]).frame(width: 8, height: 8)
                            Text(segment.name).font(.system(size: 12))
                            Spacer()
                            Text(UsageFormat.storage(segment.sizeGB)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }
                    }
                }
            } else {
                InfoNote(text: "Capacity only. No file contents are read and no categories or historical readings are fabricated.")
            }
            if !drive.historyGB.isEmpty {
                Hairline()
                SampleHistoryChart(title: "Storage over time", values: drive.historyGB, upperBound: drive.capacityGB, isPercent: false)
            }
        } else {
            ContentUnavailableView("No drives reported", systemImage: "externaldrive")
        }
    }
}

@available(macOS 14.0, *)
struct InfoNote: View {
    var text: String
    var warning = false
    var body: some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Used only for the explicit demo data's sample histories.
@available(macOS 14.0, *)
private struct SampleHistoryChart: View {
    var title: String
    var values: [Double]
    var upperBound: Double
    var isPercent: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Sample history").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            Chart(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Day", index + 1), yStart: .value("Zero", 0), yEnd: .value("Used", value))
                    .foregroundStyle(Palette.blue.opacity(0.07))
                LineMark(x: .value("Day", index + 1), y: .value("Used", value)).foregroundStyle(Palette.blue)
            }
            .chartYScale(domain: 0...max(1, upperBound))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Palette.border)
                    AxisValueLabel {
                        if let value = value.as(Double.self) { Text(isPercent ? UsageFormat.percent(value) : UsageFormat.storage(value)).foregroundStyle(Palette.secondary) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: [1, 4, 7]) { value in
                    AxisValueLabel { if let day = value.as(Int.self) { Text(day == 7 ? "Now" : "Day \(day)").foregroundStyle(Palette.secondary) } }
                }
            }
            .frame(height: 135)
        }
    }
}
