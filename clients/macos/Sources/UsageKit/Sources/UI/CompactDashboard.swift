import SwiftUI

/// A glanceable dashboard for the lower-left pane of the portrait display.
@available(macOS 14.0, *)
struct CompactDashboard: View {
    var store: UsageStore
    private var summary: CompactSummary { CompactSummary(sources: store.filteredSources) }
    private var quotaProviders: [IntegrationID] {
        summary.overview.quotaProviders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !summary.statusSources.isEmpty { SourceStatusCard(sources: summary.statusSources, store: store) }
            ForEach(summary.overview.consumptionSources) { ConsumptionCard(source: $0, store: store) }
            ForEach(quotaProviders) { provider in
                let accounts = summary.overview.quotaAccounts(provider)
                let readings = QuotaAggregate.mainReadings(sources: accounts, integration: provider)
                weeklyCard(provider, accounts: accounts, quota: readings.first { $0.durationMinutes == 10080 } ?? readings.first)
            }
            if !summary.providerReadings.isEmpty { providerCard }
            if !summary.devices.isEmpty { storageCard }
            if summary.uniqueSources.isEmpty {
                ContentUnavailableView("Connect a source", systemImage: "square.grid.2x2", description: Text("Your readings will appear here."))
            }
        }.accessibilityIdentifier("compact-dashboard")
    }

    private func weeklyCard(_ integration: IntegrationID, accounts: [UsageSource], quota: QuotaAggregate?) -> some View {
        panel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: integration.symbol).foregroundStyle(Palette.blue)
                    Text(integration.name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text((quota?.label ?? "Quota").uppercased() + " REMAINING").font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.secondary)
                }
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(quota.map { UsageFormat.percent($0.remainingPercent) } ?? "—")
                            .font(.system(size: 62, weight: .semibold)).tracking(-2.5).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text(weeklyCoverage(quota))
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }.frame(width: 150, alignment: .leading)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: min(5, max(1, accounts.count))), alignment: .leading, spacing: 14) {
                        ForEach(accounts) { source in
                            weeklyAccount(source, aggregate: quota)
                        }
                    }.frame(maxWidth: .infinity)
                }
                if let quota { UsageMeter(percent: quota.remainingPercent, height: 6, meaning: "average \(quota.label) remaining") }
            }
        }.accessibilityIdentifier("compact-\(integration.rawValue)")
            .help("Average remaining percentage across reporting accounts, not a shared token pool. Each account resets independently.")
    }

    private func weeklyCoverage(_ quota: QuotaAggregate?) -> String {
        guard let quota else { return "No live readings" }
        let count = quota.totalAccounts
        return quota.accountCount == count
            ? "All \(count) account\(count == 1 ? "" : "s") · average"
            : "\(quota.accountCount) of \(count) accounts · average"
    }

    private func weeklyAccount(_ source: UsageSource, aggregate: QuotaAggregate?) -> some View {
        let window = source.quota?.windows.first { window in
            window.usedPercent.isFinite && (aggregate.map { $0.durationMinutes == window.durationMinutes && $0.label == window.label } ?? (window.durationMinutes == 10080))
        }
        let reading = window.map { "\(UsageFormat.percent($0.remainingPercent)) \($0.label) remaining" } ?? "Quota unavailable"
        return Button { open(source) } label: {
            VStack(alignment: .leading, spacing: 7) {
                Text(source.account).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.75)
                Text(window.map { UsageFormat.percent($0.remainingPercent) } ?? "—")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if let window { UsageMeter(percent: window.remainingPercent, height: 4, meaning: "\(window.label) remaining") }
                else { Capsule().fill(Palette.track).frame(height: 4).accessibilityHidden(true) }
                if source.isStale || window == nil {
                    Text(source.isStale ? "Cached" : "Unavailable").font(.system(size: 8)).foregroundStyle(Palette.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("Open \(source.integration.name) \(source.account), \(reading)\(source.isStale ? ", cached" : "")")
            .accessibilityIdentifier("compact-\(source.id)")
            .help([source.account, source.isStale ? "Cached" : nil, window?.resetsAt.map { UsageFormat.reset($0, now: store.now) }].compactMap { $0 }.joined(separator: " · "))
    }

    private var providerCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Text("Cloud & API").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Running now").frame(width: 135, alignment: .leading)
                    Text("\(UsageFormat.month) spend").frame(width: 140, alignment: .trailing)
                }
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.bottom, 8)
                ForEach(Array(summary.providerReadings.enumerated()), id: \.element.id) { index, reading in
                    if index > 0 { Hairline().opacity(0.65) }
                    Button { store.selection = DetailSelection(sourceID: reading.id) } label: {
                        HStack(spacing: 16) {
                            HStack(spacing: 10) {
                                Image(systemName: reading.integration.symbol).font(.system(size: 15)).foregroundStyle(Palette.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reading.integration.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(reading.account).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                if let count = reading.runningCount, let noun = reading.resourceNoun {
                                    Text("\(count)").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                                    Text(noun).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                }
                            }.frame(width: 135, alignment: .leading)
                            Group {
                                if let spent = reading.spentUSD {
                                    Text(UsageFormat.money(spent)).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                                }
                            }.frame(width: 140, alignment: .trailing)
                        }.frame(minHeight: 40).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(providerLabel(reading))
                        .accessibilityIdentifier("compact-provider-\(reading.id)")
                    }
            }
        }.accessibilityIdentifier("compact-provider-readings")
            .help("Separate provider/account readings. Spending is month-to-date in USD and may lag provider billing. Missing values are omitted.")
    }

    private func providerLabel(_ reading: CompactProviderReading) -> String {
        var parts = [reading.integration.name, reading.account]
        if let count = reading.runningCount, let noun = reading.resourceNoun { parts.append("\(count) running \(noun)") }
        if let spent = reading.spentUSD { parts.append("\(UsageFormat.month) spend \(UsageFormat.money(spent))") }
        return parts.joined(separator: ", ")
    }

    private var storageCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Device storage").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(summary.devices.count) devices").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                ForEach(summary.devices) { source in
                    if let storage = source.storage {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: source.integration.symbol).font(.system(size: 14)).frame(width: 18)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(source.account).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        if source.isStale || !storage.online { Text("Cached").font(.system(size: 9)).foregroundStyle(Palette.secondary) }
                                        Spacer(minLength: 4)
                                    }
                                    ForEach(CompactSummary.storageDrives(storage)) { drive in
                                        Button { store.selection = DetailSelection(sourceID: source.id, driveID: drive.id) } label: {
                                            HStack(spacing: 10) {
                                                Text(drive.name).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                                                    .frame(width: 85, alignment: .leading).lineLimit(1)
                                                UsageMeter(percent: drive.usedPercent, height: 4)
                                                Text("\(UsageFormat.storage(drive.freeGB)) free").font(.system(size: 10, weight: .medium))
                                                    .frame(width: 86, alignment: .trailing).monospacedDigit()
                                                Text("/ \(UsageFormat.storage(drive.capacityGB))").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                                                    .frame(width: 66, alignment: .trailing).monospacedDigit()
                                                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Palette.tertiary)
                                            }.contentShape(Rectangle())
                                        }.buttonStyle(.plain).help(drive.name)
                                            .accessibilityLabel("Open \(source.account) \(drive.name), \(UsageFormat.storage(drive.freeGB)) free")
                                            .accessibilityIdentifier("compact-drive-\(source.id)-\(drive.id)")
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    private func panel<Content: View>(padding: CGFloat = 14, @ViewBuilder content: () -> Content) -> some View {
        content().padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border.opacity(0.7)))
    }
    private func open(_ source: UsageSource) { store.selection = DetailSelection(sourceID: source.id) }
}
