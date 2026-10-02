import SwiftUI

@available(macOS 14.0, *)
struct DaytonaCard: View {
    var sources: [UsageSource]
    var store: UsageStore
    @State private var accountID: String?
    private var source: UsageSource { sources.first { $0.id == accountID } ?? sources[0] }

    var body: some View {
        if let compute = source.compute {
            SourceCard(selected: store.selection?.sourceID == source.id) {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeading(integration: .daytona, title: "Daytona", subtitle: sources.count == 1 ? source.account : "\(sources.count) accounts") { store.selection = DetailSelection(sourceID: source.id) }
                    if sources.count > 1 {
                        Picker("Account", selection: $accountID) {
                            ForEach(sources) { Text($0.account).tag(Optional($0.id)) }
                        }.labelsHidden().pickerStyle(.menu).padding(.top, 10)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(compute.resources.count) running").font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.text)
                        if let limit = compute.capacity?.sandboxes { Text("of \(limit) limit").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                        Spacer(minLength: 5)
                        if compute.idleDetectionAvailable { SoftBadge(text: "\(compute.idle.count) idle") }
                    }.padding(.top, 18)
                    if let limit = compute.capacity?.sandboxes, limit > 0 { HStack(spacing: 10) {
                        UsageMeter(percent: Double(compute.resources.count) / Double(limit) * 100, height: 8)
                        Text(UsageFormat.percent(Double(compute.resources.count) / Double(limit) * 100))
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).monospacedDigit()
                    }.padding(.top, 12) } else {
                        HStack(spacing: 4) {
                            if let cpu = compute.allocatedCPU { Text("\(UsageFormat.number(cpu)) vCPU") }
                            if compute.allocatedCPU != nil && compute.allocatedMemory != nil { Text("·") }
                            if let memory = compute.allocatedMemory { Text("\(UsageFormat.number(memory)) GiB allocated") }
                        }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.top, 12)
                    }
                    if compute.spent != nil || compute.accountBalanceUSD != nil || compute.hourlyRate != nil {
                        Hairline().padding(.vertical, 14)
                        HStack(spacing: 20) {
                            if let spent = compute.spent { SmallMetric(label: "This month", value: UsageFormat.money(spent)) }
                            if let balance = compute.accountBalanceUSD {
                                if compute.spent != nil { Rectangle().fill(Palette.border).frame(width: 1, height: 39) }
                                SmallMetric(label: "Wallet balance", value: UsageFormat.money(balance))
                            } else if let rate = compute.hourlyRate {
                                if compute.spent != nil { Rectangle().fill(Palette.border).frame(width: 1, height: 39) }
                                SmallMetric(label: "Current rate", value: UsageFormat.money(rate), suffix: "/h")
                            }
                        }
                    }
                    HStack {
                        Text("\(source.isStale ? "Cached" : "Updated") \(UsageFormat.freshness(source.observedAt, now: store.now))")
                            .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                        Spacer()
                        Button { store.selection = DetailSelection(sourceID: source.id) } label: {
                            HStack(spacing: 5) { Text("View usage"); Image(systemName: "arrow.up.right").font(.system(size: 9)) }
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
                        }.buttonStyle(.plain).accessibilityIdentifier("open-daytona")
                    }.padding(.top, 14)
                }.frame(minHeight: 224)
            }.accessibilityIdentifier("card-daytona")
        } else {
            UnavailableSourceCard(source: source, store: store)
        }
    }
}

@available(macOS 14.0, *)
struct ModalCard: View {
    var sources: [UsageSource]
    var store: UsageStore
    var body: some View {
        SourceCard(selected: sources.contains { $0.id == store.selection?.sourceID }) {
            VStack(alignment: .leading, spacing: 0) {
                CardHeading(integration: .modal, title: "Modal", subtitle: "\(sources.count) accounts") { store.selection = DetailSelection(sourceID: sources[0].id) }
                VStack(spacing: 0) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        if let compute = source.compute {
                            if index > 0 { Hairline().padding(.vertical, 12) }
                            Button { store.selection = DetailSelection(sourceID: source.id) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(source.account).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                                        Spacer()
                                        if let spent = compute.spent {
                                            (Text(UsageFormat.money(spent, decimals: false)).fontWeight(.semibold) + Text(compute.budget.map { " / \(UsageFormat.money($0, decimals: false))" } ?? "").foregroundColor(Palette.secondary))
                                                .font(.system(size: 14)).monospacedDigit().foregroundStyle(Palette.text)
                                        }
                                    }
                                    if let spent = compute.spent, let budget = compute.budget, budget > 0 { HStack(spacing: 8) {
                                        UsageMeter(percent: spent / budget * 100)
                                        Text(UsageFormat.percent(spent / budget * 100))
                                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).monospacedDigit().frame(width: 29, alignment: .trailing)
                                    } } else if !compute.dailySpend.isEmpty { MiniBars(values: compute.dailySpend).frame(height: 10).opacity(0.8) }
                                    HStack(spacing: 5) {
                                        Circle().fill(Palette.green).frame(width: 4, height: 4)
                                        Text(source.isStale ? "Cached · \(UsageFormat.freshness(source.observedAt, now: store.now))" : "\(compute.resources.count) \(store.isDemo ? "running" : "containers")").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.tertiary)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Open Modal \(source.account)").accessibilityIdentifier("open-\(source.id)")
                        } else { UnavailableAccountRow(source: source, store: store).padding(.vertical, 12) }
                    }
                }.padding(.top, 18)
                Spacer(minLength: 12)
                Text(store.isDemo ? "Monthly budgets · Set by you" : "Month-to-date billing · UTC · May lag").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            }.frame(minHeight: 224)
        }.accessibilityIdentifier("card-modal")
    }
}

@available(macOS 14.0, *)
struct OpenAICard: View {
    var sources: [UsageSource]
    var store: UsageStore
    @State private var accountID: String?
    private var source: UsageSource { sources.first { $0.id == accountID } ?? sources[0] }
    var body: some View {
        if let spend = source.spend {
            SourceCard(selected: store.selection?.sourceID == source.id) {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeading(integration: .openaiAPI, title: "OpenAI API", subtitle: sources.count == 1 ? source.account : "\(sources.count) accounts") { store.selection = DetailSelection(sourceID: source.id) }
                    if sources.count > 1 {
                        Picker("Account", selection: $accountID) { ForEach(sources) { Text($0.account).tag(Optional($0.id)) } }.labelsHidden().pickerStyle(.menu).padding(.top, 8)
                    }
                    Button { store.selection = DetailSelection(sourceID: source.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(UsageFormat.money(spend.spent)).font(.system(size: 32, weight: .semibold)).tracking(-0.7).foregroundStyle(Palette.text)
                                if let budget = spend.budget { Text("/ \(UsageFormat.money(budget, decimals: false)) budget").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                            }.monospacedDigit()
                            Text("\(UsageFormat.month) spend").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.top, 18).accessibilityIdentifier("open-openai")
                    if let budget = spend.budget, budget > 0 { HStack(spacing: 10) {
                        UsageMeter(percent: spend.spent / budget * 100, height: 8)
                        Text(UsageFormat.percent(spend.spent / budget * 100)).font(.system(size: 12)).foregroundStyle(Palette.secondary).monospacedDigit()
                    }.padding(.top, 12) }
                    HStack(alignment: .bottom, spacing: 24) {
                        MiniBars(values: spend.dailySpend).frame(height: 28)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Today").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            Text(UsageFormat.money(spend.today)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text).monospacedDigit()
                        }
                    }.padding(.top, 16)
                    Spacer(minLength: 14)
                    Text("\(spend.budget == nil ? "Organization costs · UTC" : "Budget set by you") · \(source.isStale ? "Cached" : "Updated") \(UsageFormat.freshness(source.observedAt, now: store.now))")
                        .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                }.frame(minHeight: 224)
            }.accessibilityIdentifier("card-openai")
        } else {
            UnavailableSourceCard(source: source, store: store)
        }
    }
}

@available(macOS 14.0, *)
struct CodexCard: View {
    var sources: [UsageSource]
    var store: UsageStore
    private var integration: IntegrationID { sources.first?.integration ?? .codex }
    private var aggregates: [QuotaAggregate] { QuotaAggregate.mainReadings(sources: sources, integration: integration) }
    var body: some View {
        SourceCard(selected: sources.contains { $0.id == store.selection?.sourceID }) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    SourceIcon(integration: integration, size: 26)
                    Text(integration.name).font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    Text("\(sources.count) accounts").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text("Remaining quota").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                HStack(alignment: .top, spacing: 36) {
                    if !aggregates.isEmpty {
                        aggregateSummary.frame(width: 255, alignment: .leading)
                        Rectangle().fill(Palette.border).frame(width: 1)
                    }
                    accountList.frame(maxWidth: .infinity)
                }.fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }.accessibilityIdentifier("card-\(integration.rawValue)")
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                if let quota = source.quota, !quota.allWindows.isEmpty {
                    Button { store.selection = DetailSelection(sourceID: source.id) } label: {
                        HStack(spacing: 22) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.account).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                                if source.isStale { Text("Cached").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                            }.frame(width: 112, alignment: .leading).help(source.accountIdentity ?? source.account)
                            if integration == .claude {
                                quotaCell(quota.shortWindow)
                                quotaCell(quota.weeklyWindow)
                            } else { quotaCell(quota.mostUsedWindow) }
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.tertiary)
                        }.padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Open \(integration.name) \(source.account)").accessibilityIdentifier("open-\(source.id)")
                } else {
                    UnavailableAccountRow(source: source, store: store).padding(.vertical, 16)
                }
                if index < sources.count - 1 { Hairline() }
            }
        }
    }

    private func quotaCell(_ window: QuotaWindow?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let window {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(window.label + (window.resetsAt.map { " · \(UsageFormat.reset($0, now: store.now))" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(UsageFormat.percent(window.remainingPercent)).font(.system(size: 22, weight: .semibold))
                        .monospacedDigit().foregroundStyle(Palette.text).fixedSize()
                }
                UsageMeter(percent: window.remainingPercent, height: 9, meaning: "remaining")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aggregateSummary: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("All \(sources.count) accounts").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.secondary)
            ForEach(aggregates) { value in
                VStack(alignment: .leading, spacing: 14) {
                    Text(UsageFormat.percent(value.remainingPercent)).font(.system(size: 76, weight: .semibold))
                        .tracking(-3).monospacedDigit().foregroundStyle(Palette.text)
                    Text("\(value.label) remaining").font(.system(size: 17, weight: .medium))
                    UsageMeter(percent: value.remainingPercent, height: 11, meaning: "remaining")
                    Text("Average across your accounts").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    if value.accountCount < value.totalAccounts {
                        Text("\(value.accountCount) of \(value.totalAccounts) accounts reporting").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                }.help("Equal-weight average across \(value.accountCount) of \(value.totalAccounts) accounts. Matching windows only; cached readings excluded. Account allowances and resets are independent.")
            }
        }.padding(.vertical, 12).accessibilityIdentifier("\(integration.rawValue)-main-aggregate")
    }
}

@available(macOS 14.0, *)
struct StorageCard: View {
    var sources: [UsageSource]
    var store: UsageStore
    var body: some View {
        SourceCard(selected: sources.contains { $0.id == store.selection?.sourceID }) {
            VStack(alignment: .leading, spacing: 0) {
                CardHeading(title: "Storage", subtitle: "\(sources.count) devices") { store.selection = DetailSelection(sourceID: sources[0].id) }
                VStack(spacing: 0) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        if let storage = source.storage {
                            if index > 0 { Hairline().padding(.vertical, 12) }
                            HStack(spacing: 9) {
                                Image(systemName: source.integration.symbol).font(.system(size: 16)).foregroundStyle(Palette.text).frame(width: 20)
                                Text(source.account).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                                Spacer(minLength: 4)
                                HStack(spacing: 5) {
                                    if storage.online { Circle().fill(Palette.green).frame(width: 5, height: 5) }
                                    else { Image(systemName: "clock").font(.system(size: 10)) }
                                    Text(storage.online ? "Live" : "Seen \(UsageFormat.freshness(source.observedAt, now: store.now))")
                                }.font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize()
                            }.padding(.bottom, 9)
                            VStack(spacing: 9) {
                                ForEach(storage.drives) { drive in
                                    Button { store.selection = DetailSelection(sourceID: source.id, driveID: drive.id) } label: {
                                        HStack(alignment: .top, spacing: 14) {
                                            Text(drive.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.text).frame(width: 100, alignment: .leading).lineLimit(1)
                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack(spacing: 10) {
                                                    UsageMeter(percent: drive.usedPercent, height: 6)
                                                    Text("\(UsageFormat.storage(drive.freeGB)) free").font(.system(size: 11, weight: .medium))
                                                        .foregroundStyle(Palette.text)
                                                        .frame(width: 88, alignment: .trailing)
                                                }.monospacedDigit()
                                                HStack {
                                                    Text("\(UsageFormat.storage(drive.usedGB)) / \(UsageFormat.storage(drive.capacityGB)) used")
                                                    Spacer()
                                                    Text(UsageFormat.percent(drive.usedPercent))
                                                }.font(.system(size: 9)).foregroundStyle(Palette.tertiary)
                                            }
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Open \(source.account) \(drive.name)").accessibilityIdentifier("open-drive-\(drive.id)")
                                }
                            }
                        } else { UnavailableAccountRow(source: source, store: store).padding(.vertical, 14) }
                    }
                }.padding(.top, 16)
            }.frame(minHeight: 272, alignment: .top)
        }.accessibilityIdentifier("card-storage")
    }
}

@available(macOS 14.0, *)
struct UnavailableAccountRow: View {
    var source: UsageSource
    var store: UsageStore
    var showProvider = false
    var body: some View {
        Button { store.selection = DetailSelection(sourceID: source.id) } label: {
            HStack(spacing: 12) {
                if showProvider { SourceIcon(integration: source.integration, size: 21) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(showProvider ? "\(source.name) · \(source.account)" : source.account)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                    if let identity = source.accountIdentity {
                        Text(identity).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(source.readingStatusTitle).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("Open \(source.name) \(source.account), \(source.readingStatusTitle)")
            .accessibilityIdentifier("open-status-\(source.id)")
            .help(source.unavailable?.message ?? source.readingStatusTitle)
    }
}

@available(macOS 14.0, *)
struct SourceStatusCard: View {
    var sources: [UsageSource]
    var store: UsageStore
    var body: some View {
        SourceCard(selected: sources.contains { $0.id == store.selection?.sourceID }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Source status").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { Hairline() }
                    UnavailableAccountRow(source: source, store: store, showProvider: true)
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("source-status-card")
    }
}

@available(macOS 14.0, *)
struct UnavailableSourceCard: View {
    var source: UsageSource
    var store: UsageStore
    var body: some View {
        SourceCard {
            VStack(alignment: .leading, spacing: 16) {
                CardHeading(integration: source.integration, title: source.name, subtitle: source.account) { store.selection = DetailSelection(sourceID: source.id) }
                Image(systemName: "key.horizontal").font(.system(size: 23)).foregroundStyle(Palette.tertiary).padding(.top, 6)
                Text(source.unavailable?.title ?? "Unavailable").font(.system(size: 17, weight: .semibold))
                Text(source.unavailable?.message ?? "This source has no reading yet.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(3)
                Spacer(minLength: 0)
                Button("Manage connection") { store.page = "Connections"; store.selection = nil }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.blue)
            }.frame(minHeight: 224, alignment: .top)
        }
    }
}
