import SwiftUI

@available(macOS 14.0, *)
struct ConsumptionCard: View {
    var source: UsageSource
    var store: UsageStore

    var body: some View {
        if let usage = source.consumption, usage.hasReading {
            SourceCard(selected: store.selection?.sourceID == source.id) {
                Button { store.selection = DetailSelection(sourceID: source.id) } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 14) {
                            SourceIcon(integration: source.integration, size: 20)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name).font(.system(size: 15, weight: .semibold))
                                Text(source.account).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                if let identity = source.accountIdentity {
                                    Text(identity).font(.system(size: 10)).foregroundStyle(Palette.tertiary).lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(usage.formattedAmount).font(.system(size: 32, weight: .semibold))
                                    .tracking(-0.6).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                                Text(usage.usedLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                                if let period = usage.period {
                                    Text(period.label).font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                                }
                            }
                        }
                        HStack {
                            Text("\(source.isStale ? "Cached" : "Updated") \(UsageFormat.freshness(source.observedAt, now: store.now))")
                                .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.tertiary)
                        }
                    }.foregroundStyle(Palette.text).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Open \(source.name) \(source.account), \(usage.formattedAmount) \(usage.usedLabel)\(source.isStale ? ", cached" : "")")
                    .accessibilityIdentifier("open-consumption-\(source.id)")
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("card-consumption-\(source.id)")
        }
    }
}

@available(macOS 14.0, *)
struct ConsumptionDetailView: View {
    var source: UsageSource
    var usage: ConsumptionUsage

    var body: some View {
        DetailTitle(title: "Usage", subtitle: usage.period?.label ?? source.account)
        if let identity = source.accountIdentity {
            Label(identity, systemImage: "person.crop.circle").font(.system(size: 12))
                .foregroundStyle(Palette.secondary).textSelection(.enabled)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(usage.formattedAmount).font(.system(size: 46, weight: .semibold)).tracking(-1).monospacedDigit()
            Text(usage.usedLabel).font(.system(size: 14)).foregroundStyle(Palette.secondary)
        }.accessibilityElement(children: .combine)
        if let plan = usage.plan {
            Hairline()
            Text(plan).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }
}
