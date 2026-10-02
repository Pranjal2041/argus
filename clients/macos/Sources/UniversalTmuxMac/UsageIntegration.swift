import SwiftUI
import UsageKit
import UniformTypeIdentifiers

@available(macOS 14.0, *)
struct UsageCardDrag: Codable, Transferable {
    let sessionID: UUID
    let cardID: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "dev.universaltmux.usage-card"))
    }

    @MainActor
    static func drop(_ items: [Self], sessionID: UUID, targetID: String,
                     placement: UsageCardPlacement, usage: UsageController) -> Bool {
        guard items.count == 1, let item = items.first, item.sessionID == sessionID else { return false }
        return usage.moveGlance(item.cardID, relativeTo: targetID, placement: placement)
    }
}

@available(macOS 14.0, *)
@MainActor
enum ArgusUsage {
    static let shared = UsageController()
}

@available(macOS 14.0, *)
struct UsageWorkspaceView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var usage: UsageController
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { try? state.navigate(to: .commandCenter) } label: {
                    Label("Command Center", systemImage: "chevron.left")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { usage.showSettings = true } label: {
                    Label("Warnings & refresh", systemImage: "slider.horizontal.3")
                }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            }.font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 16)
                .background(Theme.appBackground)
            UsageDashboard(controller: usage)
        }
        .sheet(isPresented: $usage.showSettings) { UsageWarningSettings(controller: usage) }
    }
}

@available(macOS 14.0, *)
struct UsageCommandCenterSection: View {
    private static let cardWidth: CGFloat = 236
    private static let cardPadding: CGFloat = 14
    @ObservedObject var usage: UsageController
    var open: () -> Void
    @State private var showAllWarnings = false
    @State private var arranging = false
    @State private var dragSessionID = UUID()
    @State private var targetedCardID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(Theme.accent)
                Text("Usage").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let date = usage.lastRefresh {
                    Text(date, style: .relative).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        .help("Last usage refresh")
                }
                Spacer()
                if usage.connectionIssueCount > 0 {
                    Button("\(usage.connectionIssueCount) connection\(usage.connectionIssueCount == 1 ? "" : "s") to check") {
                        usage.openConnections(); open()
                    }.font(.system(size: 11)).foregroundStyle(Theme.waiting)
                }
                if arranging {
                    Button("Reset order") { withAnimation { usage.resetCardOrder() } }
                        .disabled(!usage.hasCustomCardOrder).accessibilityIdentifier("usage-reset-card-order")
                }
                Button { withAnimation { arranging.toggle() } } label: {
                    Label(arranging ? "Done" : "Arrange", systemImage: arranging ? "checkmark" : "arrow.left.arrow.right")
                }.disabled(usage.glances.count < 2 && !arranging)
                    .help("Drag cards to rearrange, or use the left and right buttons.")
                    .accessibilityIdentifier("usage-arrange-cards")
                Button { Task { await usage.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.disabled(usage.refreshing).help("Refresh usage").accessibilityIdentifier("usage-refresh")
                Button { usage.showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }.help("Configure usage warnings").accessibilityIdentifier("usage-warning-settings")
                Button { usage.open(); open() } label: {
                    Label("All usage", systemImage: "arrow.up.right")
                }.accessibilityIdentifier("usage-open-dashboard")
            }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            if usage.glances.isEmpty {
                Button { usage.open(); open() } label: {
                    HStack(spacing: 12) {
                        Text(usage.refreshing ? "Reading your connected accounts…" : "Connect accounts to see limits, spending, and storage.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.accent)
                    }.padding(16).background(Theme.surface.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 10) {
                        ForEach(usage.glances) { item in
                            reorderableMetric(item)
                        }
                    }.padding(.bottom, 5)
                }
            }
            ForEach(showAllWarnings ? usage.warnings : Array(usage.warnings.prefix(3))) { warning in
                warningRow(warning)
            }
            if usage.warnings.count > 3 {
                Button(showAllWarnings ? "Show fewer warnings" : "\(usage.warnings.count - 3) more usage warnings") {
                    showAllWarnings.toggle()
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.waiting)
            }
        }
        .sheet(isPresented: $usage.showSettings) { UsageWarningSettings(controller: usage) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-command-center")
    }

    private func reorderableMetric(_ item: UsageGlance) -> some View {
        VStack(spacing: 6) {
            Button {
                if !arranging { usage.open(sourceID: item.sourceID); open() }
            } label: { metric(item) }
                .buttonStyle(.plain).accessibilityIdentifier("usage-metric-\(item.id)")
            if arranging {
                HStack(spacing: 12) {
                    Button { withAnimation { _ = usage.moveGlance(item.id, by: -1) } } label: { Image(systemName: "arrow.left") }
                        .disabled(usage.glances.first?.id == item.id)
                        .accessibilityLabel("Move \(item.title) left").accessibilityIdentifier("usage-move-left-\(item.id)")
                    Spacer()
                    Label("Drag to move", systemImage: "line.3.horizontal")
                        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button { withAnimation { _ = usage.moveGlance(item.id, by: 1) } } label: { Image(systemName: "arrow.right") }
                        .disabled(usage.glances.last?.id == item.id)
                        .accessibilityLabel("Move \(item.title) right").accessibilityIdentifier("usage-move-right-\(item.id)")
                }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12).frame(width: Self.cardWidth, height: 26)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .draggable(UsageCardDrag(sessionID: dragSessionID, cardID: item.id))
        .dropDestination(for: UsageCardDrag.self) { items, location in
            withAnimation(.easeInOut(duration: 0.18)) {
                UsageCardDrag.drop(items, sessionID: dragSessionID, targetID: item.id,
                    placement: location.x < Self.cardWidth / 2 ? .before : .after, usage: usage)
            }
        } isTargeted: { targeted in
            if targeted { targetedCardID = item.id }
            else if targetedCardID == item.id { targetedCardID = nil }
        }
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(targetedCardID == item.id ? Theme.accent : .clear, lineWidth: 2))
        .contextMenu {
            Button("Move left") { withAnimation { _ = usage.moveGlance(item.id, by: -1) } }
                .disabled(usage.glances.first?.id == item.id)
            Button("Move right") { withAnimation { _ = usage.moveGlance(item.id, by: 1) } }
                .disabled(usage.glances.last?.id == item.id)
            if let first = usage.glances.first {
                Button("Move to beginning") { withAnimation { _ = usage.moveGlance(item.id, relativeTo: first.id, placement: .before) } }
                    .disabled(first.id == item.id)
            }
            if let last = usage.glances.last {
                Button("Move to end") { withAnimation { _ = usage.moveGlance(item.id, relativeTo: last.id, placement: .after) } }
                    .disabled(last.id == item.id)
            }
        }
        .help("Drag to rearrange. \(arranging ? "Use the arrows for one position at a time." : "Click to open usage.")")
        .accessibilityElement(children: .contain)
    }

    private func metric(_ item: UsageGlance) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(item.title, systemImage: item.symbol)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(item.value).font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(Theme.textPrimary)
            Text(item.detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(2)
            if let remaining = item.remaining {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border)
                        Capsule().fill(Theme.accent).frame(width: geometry.size.width * min(100, max(0, remaining)) / 100)
                    }
                }.frame(height: 3)
            }
        }.frame(width: Self.cardWidth - Self.cardPadding * 2, height: 101, alignment: .topLeading)
            .padding(Self.cardPadding).background(Theme.surface.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border.opacity(0.7)))
    }

    private func warningRow(_ warning: UsageWarning) -> some View {
        HStack(spacing: 12) {
            Image(systemName: warning.critical ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.0percent")
                .foregroundStyle(Theme.waiting)
            Button { usage.open(warning); open() } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(warning.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text(warning.detail)
                        if let reset = warning.resetsAt { Text("· resets"); Text(reset, style: .relative) }
                    }.font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { usage.dismiss(warning, snooze: true) } label: { Image(systemName: "clock") }
                .help("Snooze this warning").accessibilityLabel("Snooze \(warning.title)")
            Button { usage.dismiss(warning) } label: { Image(systemName: "xmark") }
                .help("Dismiss until reset or recovery").accessibilityLabel("Dismiss \(warning.title)")
                .accessibilityIdentifier("usage-dismiss-\(warning.id)")
        }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            .padding(12).background(Theme.waiting.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.waiting.opacity(0.2)))
    }
}
