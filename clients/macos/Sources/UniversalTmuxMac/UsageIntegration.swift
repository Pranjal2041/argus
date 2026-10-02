import SwiftUI
import UsageKit

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
    @ObservedObject var usage: UsageController
    var open: () -> Void
    @State private var showAllWarnings = false

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
                            Button { usage.open(sourceID: item.sourceID); open() } label: { metric(item) }
                                .buttonStyle(.plain).accessibilityIdentifier("usage-metric-\(item.id)")
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
        }.frame(width: 208, height: 101, alignment: .topLeading)
            .padding(14).background(Theme.surface.opacity(0.65))
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
