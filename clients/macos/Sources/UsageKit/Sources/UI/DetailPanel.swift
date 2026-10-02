import AppKit
import Charts
import SwiftUI

@available(macOS 14.0, *)
struct DetailPanel: View {
    var source: UsageSource
    @Bindable var store: UsageStore
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SourceIcon(integration: source.integration, size: 16)
                Text(source.storage == nil ? source.name : "Storage").font(.system(size: 12, weight: .semibold))
                Text("/").foregroundStyle(Palette.tertiary)
                let siblings = store.sources.filter { $0.integration == source.integration }
                if siblings.count > 1 {
                    Menu {
                        ForEach(siblings) { sibling in
                            Button(sibling.account) { store.selection = DetailSelection(sourceID: sibling.id) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(source.account).font(.system(size: 12))
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }.foregroundStyle(Palette.secondary)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Switch account")
                } else {
                    Text(source.account).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                IconButton(symbol: "xmark", label: "Close details") { store.selection = nil }
                    .accessibilityIdentifier("close-details")
            }.padding(.horizontal, 22).frame(height: 58)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    if source.isStale {
                        Label("Cached reading · \(UsageFormat.freshness(source.observedAt, now: store.now))", systemImage: "clock")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                    }
                    if let compute = source.compute {
                        if source.capabilities != nil {
                            SourceAccessView(source: source, includeUnavailable: false)
                            if source.hasLimitedAccess {
                                Button("Update connection") {
                                    store.selection = nil; store.page = "Connections"
                                    if let config = store.configuration?.sources.first(where: { $0.id == source.id }) { store.editConnection(config) }
                                }.buttonStyle(SecondaryButtonStyle())
                            }
                            Hairline()
                        }
                        ComputeDetailView(source: source, compute: compute, now: store.now)
                    } else if let spend = source.spend {
                        SpendDetailView(source: source, spend: spend, now: store.now)
                    } else if let quota = source.quota {
                        QuotaDetailView(source: source, quota: quota, now: store.now)
                    } else if let storage = source.storage {
                        StorageDetailView(source: source, storage: storage, selectedDriveID: Binding(
                            get: { store.selection?.driveID },
                            set: { store.selection = DetailSelection(sourceID: source.id, driveID: $0) }
                        ), now: store.now)
                    } else if let unavailable = source.unavailable {
                        DetailTitle(title: unavailable.title, subtitle: source.account)
                        Text(unavailable.message).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        Button("Manage connection") { store.selection = nil; store.page = "Connections" }.buttonStyle(PrimaryButtonStyle())
                    }
                    if !source.notes.isEmpty {
                        Hairline()
                        ForEach(source.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(24).id(source.id)
            }
            Hairline()
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "circle.dotted").font(.system(size: 10))
                    Text(source.origin == .demo ? "Demo source" : (source.isStale ? "Cached reading" : "Live source")).font(.system(size: 10))
                }.foregroundStyle(Palette.tertiary)
                if store.isAdded(source.id) {
                    Menu {
                        Button("Remove demo source", role: .destructive) { store.removeAddedSource(source.id) }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Source options")
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy summary", systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("copy-summary")
            }.padding(.horizontal, 24).padding(.vertical, 15)
        }
        .onChange(of: source.id) { _, _ in copied = false }
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        var lines = ["\(source.name) · \(source.account)", source.origin == .demo ? "Sample data" : (source.isStale ? "Cached data" : "Live data")]
        if let compute = source.compute {
            lines.append("\(compute.resources.count) running")
            if compute.idleDetectionAvailable { lines.append("\(compute.idle.count) idle") }
            if let spent = compute.spent { lines.append("\(UsageFormat.money(spent)) this month") }
            if let rate = compute.hourlyRate { lines.append("\(UsageFormat.money(rate))/h") }
            lines += (source.capabilities ?? []).filter { $0.status != .available }.map { "\($0.label): \($0.message)" }
        } else if let spend = source.spend {
            lines.append("\(UsageFormat.money(spend.spent)) this month")
            if let budget = spend.budget { lines.append("\(UsageFormat.money(budget)) monthly budget") }
        } else if let quota = source.quota {
            lines += quota.windows.map { "\($0.label): \(UsageFormat.percent($0.remainingPercent)) remaining" }
            lines += quota.additionalBuckets.flatMap { bucket in bucket.windows.map { "\(bucket.name) · \($0.label): \(UsageFormat.percent($0.remainingPercent)) remaining" } }
        } else if let storage = source.storage {
            lines += storage.drives.map { "\($0.name): \(UsageFormat.storage($0.freeGB)) free / \(UsageFormat.storage($0.capacityGB))" }
        }
        lines.append("Observed \(source.observedAt.formatted())")
        return lines.joined(separator: "\n")
    }
}

@available(macOS 14.0, *)
struct DetailTitle: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.4).foregroundStyle(Palette.text)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
    }
}

@available(macOS 14.0, *)
struct ComputeDetailView: View {
    var source: UsageSource
    var compute: ComputeUsage
    var now: Date
    @State private var filtered = false
    @State private var expandedResource: String?
    private var isSandbox: Bool { source.integration == .daytona }
    private var filteredResources: [ComputeResource] {
        guard filtered else { return compute.resources }
        return compute.resources.filter { isSandbox ? $0.state == .idle : $0.kind == "GPU" }
    }

    var body: some View {
        DetailTitle(title: isSandbox ? "Sandboxes" : (source.origin == .live ? "Containers & billing" : "Running jobs"), subtitle: "Updated \(UsageFormat.freshness(source.observedAt, now: now))")

        if let counts = compute.inventoryCounts {
            Text("\(counts.values.reduce(0, +)) total · \(counts["stopped", default: 0]) stopped · \(counts["paused", default: 0]) paused · \(counts["archived", default: 0]) archived")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }

        HStack(alignment: .top, spacing: 20) {
            capacityMetric("Running", value: Double(compute.resources.count), limit: compute.capacity?.sandboxes.map(Double.init))
            if let cpu = compute.allocatedCPU { capacityMetric("Allocated CPU", value: cpu, limit: compute.capacity?.cpu, unit: "vCPU") }
            if let memory = compute.allocatedMemory { capacityMetric("Allocated memory", value: memory, limit: compute.capacity?.memoryGiB, unit: "GiB") }
        }
        Hairline()
        if compute.spent != nil || compute.hourlyRate != nil || compute.accountBalanceUSD != nil {
            HStack(spacing: 30) {
                if let spent = compute.spent { SmallMetric(label: "\(UsageFormat.month) spend", value: UsageFormat.money(spent)) }
                if let rate = compute.hourlyRate { SmallMetric(label: "Current rate", value: UsageFormat.money(rate), suffix: "/h") }
                if let balance = compute.accountBalanceUSD { SmallMetric(label: "Wallet balance", value: UsageFormat.money(balance)) }
            }
        }
        if let budget = compute.budget, let spent = compute.spent, budget > 0 {
            VStack(spacing: 9) {
                HStack {
                    Text("Monthly budget").foregroundStyle(Palette.secondary)
                    Spacer()
                    Text("\(UsageFormat.money(compute.spent, decimals: false)) / \(UsageFormat.money(budget, decimals: false))")
                }.font(.system(size: 11)).monospacedDigit()
                UsageMeter(percent: spent / budget * 100)
            }
        }

        if let count = compute.periodSandboxCount {
            Text("\(count) sandboxes incurred usage this month, including historical sandboxes.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
        if !compute.dailySpend.isEmpty {
            SpendChart(values: compute.dailySpend, dates: compute.dailySpendDates, title: compute.spendChartTitle ?? "Daily spend")
            if let note = compute.spendChartNote { InfoNote(text: note) }
        }
        if !compute.billingBreakdown.isEmpty {
            SpendingBreakdownView(title: compute.spendBreakdownTitle ?? (isSandbox ? "Billing by resource" : "Billing by app / object"), rows: compute.billingBreakdown, total: compute.spent ?? 0)
        }

        if !compute.idle.isEmpty {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(compute.idle.count) idle sandboxes · \(UsageFormat.money(compute.idle.compactMap(\.hourlyRate).reduce(0, +)))/h combined")
                        .font(.system(size: 12, weight: .medium))
                    Text("Still running and accruing cost").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
            }.foregroundStyle(Palette.secondary).padding(13).background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 7))
        }

        VStack(spacing: 12) {
            HStack {
                if compute.idleDetectionAvailable { Picker("Resource filter", selection: $filtered) {
                    Text("All \(compute.resources.count)").tag(false)
                    Text(isSandbox ? "Idle \(compute.idle.count)" : "GPU \(compute.resources.filter { $0.kind == "GPU" }.count)").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 166).accessibilityIdentifier("resource-filter") }
                Spacer()
                Text("\(filteredResources.count) \(source.origin == .live ? compute.resourceNoun : (isSandbox ? "sandboxes" : "jobs"))").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            }
            resourceTable
        }

        if !compute.providerCapacity.isEmpty {
            Hairline()
            Text("Regional capacity").font(.system(size: 14, weight: .semibold))
            ForEach(compute.providerCapacity) { metric in
                VStack(spacing: 7) {
                    HStack {
                        Text(metric.label)
                        Spacer()
                        Text("\(UsageFormat.number(metric.used)) / \(UsageFormat.number(metric.limit)) \(metric.unit)")
                    }.font(.system(size: 11))
                    UsageMeter(percent: metric.used / metric.limit * 100)
                }
            }
        }
    }

    private func capacityMetric(_ label: String, value: Double?, limit: Double?, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
            (Text(limit.map { "\(UsageFormat.number(value)) / \(UsageFormat.number($0))" } ?? UsageFormat.number(value)).font(.system(size: 18, weight: .medium)) + Text(unit.isEmpty ? "" : " \(unit)").font(.system(size: 11)))
                .foregroundStyle(Palette.text).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            if let limit, let value, limit > 0 {
                HStack(spacing: 6) {
                    UsageMeter(percent: Double(value) / Double(max(1, limit)) * 100, height: 6)
                    Text(UsageFormat.percent(Double(value) / Double(max(1, limit)) * 100)).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resourceTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(isSandbox ? "Sandbox" : (source.origin == .live ? "Container / app" : "Job")).frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 73, alignment: .leading)
                if compute.resources.contains(where: { $0.startedAt != nil }) { Text("Running for").frame(width: 70, alignment: .leading) }
                if compute.ratesAvailable { Text("Rate").frame(width: 64, alignment: .trailing) }
                Color.clear.frame(width: 8)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary).padding(.vertical, 10)
            Hairline()
            ForEach(filteredResources) { resource in
                VStack(spacing: 0) {
                    Button { withAnimation(.easeInOut(duration: 0.18)) { expandedResource = expandedResource == resource.id ? nil : resource.id } } label: {
                        HStack(spacing: 10) {
                            Text(resource.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.text)
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            HStack(spacing: 5) {
                                Circle().frame(width: 5, height: 5)
                                Text(resource.state == .idle ? "Idle" : "Running")
                            }.font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(width: 73, alignment: .leading)
                            if compute.resources.contains(where: { $0.startedAt != nil }) { Text(resource.startedAt.map { UsageFormat.duration(now.timeIntervalSince($0)) } ?? "").font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(width: 70, alignment: .leading) }
                            if compute.ratesAvailable { Text(resource.hourlyRate.map { "\(UsageFormat.money($0))/h" } ?? "").font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(width: 64, alignment: .trailing) }
                            Image(systemName: expandedResource == resource.id ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundStyle(Palette.tertiary).frame(width: 8)
                        }.padding(.vertical, 11).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("resource-\(resource.id)")
                    if expandedResource == resource.id {
                        HStack(spacing: 16) {
                            if let cpu = resource.cpu { Label("\(UsageFormat.number(cpu)) vCPU", systemImage: "cpu") }
                            if let memory = resource.memoryGiB { Label("\(UsageFormat.number(memory)) GiB", systemImage: "memorychip") }
                            Spacer()
                            Text(resource.kind)
                        }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
                            .padding(.bottom, 12).accessibilityIdentifier("resource-expanded-\(resource.id)")
                    }
                }
                .padding(.horizontal, 7)
                .clipShape(RoundedRectangle(cornerRadius: 5)).padding(.horizontal, -7)
                Hairline().opacity(resource.state == .idle ? 0 : 1)
            }
            if filteredResources.isEmpty {
                Text(filtered ? (isSandbox ? "No idle sandboxes" : "No GPU jobs running") : "No running \(compute.resourceNoun)").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(25)
            }
        }
    }
}

@available(macOS 14.0, *)
struct SpendChart: View {
    var values: [Double]
    var dates: [Date] = []
    var title = "Daily spend"
    @State private var showAll = false
    private var visible: [Double] { showAll ? values : Array(values.suffix(7)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Chart range", selection: $showAll) {
                    Text("7 days").tag(false)
                    Text("All data").tag(true)
                }.labelsHidden().pickerStyle(.menu).frame(width: 94).controlSize(.small)
            }
            Chart(Array(visible.enumerated()), id: \.offset) { index, value in
                BarMark(x: .value("Day", day(index), unit: .day), y: .value("Spend", value), width: .ratio(0.58))
                    .foregroundStyle(Palette.blue.opacity(0.78)).cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: visible.count > 14 ? 4 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.day(), centered: true).foregroundStyle(Palette.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Palette.border)
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(UsageFormat.money(amount, decimals: false)).foregroundStyle(Palette.secondary) } }
                }
            }
            .frame(height: 120)
            .accessibilityLabel("\(title), \(visible.count) days, total \(UsageFormat.money(visible.reduce(0, +)))")
        }
    }
    private func day(_ index: Int) -> Date {
        let dateIndex = values.count - visible.count + index
        if dates.indices.contains(dateIndex) {
            // Anchor to local noon on the provider's UTC calendar date so chart day labels
            // do not shift to the previous date in a negative-offset local timezone.
            var components = UsageCalendar.utc.dateComponents([.year, .month, .day], from: dates[dateIndex])
            components.hour = 12
            return Calendar.current.date(from: components)!
        }
        return Calendar.current.date(byAdding: .day, value: index - visible.count + 1, to: DemoData.scenarioTime)!
    }
}
