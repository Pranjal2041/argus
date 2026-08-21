import AppKit
import SwiftUI

/// A dedicated registry for restartable web services. This is intentionally
/// separate from the file-oriented Artifacts library: nothing here is a PDF,
/// screenshot, render, or saved file.
struct WebArtifactsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var webArtifacts: WebArtifactStore
    @EnvironmentObject private var dashboards: DashboardsModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ut.uiScale") private var uiScale = 1.0

    @State private var query = ""
    @State private var availability: Availability = .all
    @State private var sortOrder: SortOrder = .newest
    @State private var deleteCandidate: WebArtifactItem?

    private enum Availability: String, CaseIterable, Identifiable {
        case all = "All"
        case available = "Available"
        case offline = "Offline"
        var id: String { rawValue }
    }

    private enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case name = "Name"
        case machine = "Machine"
        var id: String { rawValue }
    }

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var visibleItems: [WebArtifactItem] {
        webArtifacts.matching(query: query)
            .filter { item in
                switch availability {
                case .all: return true
                case .available: return item.reachable
                case .offline: return !item.reachable
                }
            }
            .sorted { lhs, rhs in
                switch sortOrder {
                case .newest:
                    if lhs.recipe.updatedAt != rhs.recipe.updatedAt {
                        return lhs.recipe.updatedAt > rhs.recipe.updatedAt
                    }
                case .name:
                    let order = lhs.recipe.name.localizedCaseInsensitiveCompare(rhs.recipe.name)
                    if order != .orderedSame { return order == .orderedAscending }
                case .machine:
                    let order = lhs.recipe.machineName.localizedCaseInsensitiveCompare(rhs.recipe.machineName)
                    if order != .orderedSame { return order == .orderedAscending }
                }
                return lhs.recipe.name.localizedCaseInsensitiveCompare(rhs.recipe.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            controls
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.appBackground)
        .task { await webArtifacts.refresh(machines: state.machines) }
        .onChange(of: state.machines) { _ in
            Task { await webArtifacts.refresh(machines: state.machines) }
        }
        .alert("Web Artifacts", isPresented: Binding(
            get: { webArtifacts.errorMessage != nil },
            set: { if !$0 { webArtifacts.errorMessage = nil } }
        )) {
            Button("OK") { webArtifacts.errorMessage = nil }
        } message: {
            Text(webArtifacts.errorMessage ?? "The web artifact could not be opened.")
        }
        .confirmationDialog(
            "Delete \(deleteCandidate?.recipe.name ?? "this web artifact")?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete saved recipe", role: .destructive) {
                guard let item = deleteCandidate else { return }
                deleteCandidate = nil
                Task { await webArtifacts.delete(item) }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("This removes the saved recipe. A service that is already running will not be stopped.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(0.13))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(cf(17, .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Web Artifacts")
                    .font(cf(21, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Saved recipes for web tools you want to reopen later")
                    .font(cf(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 16)
            Text("\(webArtifacts.items.count) saved")
                .font(cf(11, .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("\(webArtifacts.items.filter(\.reachable).count) available")
                .font(cf(11, .medium))
                .foregroundStyle(Theme.attached)
            Button {
                state.showWebArtifacts = false
            } label: {
                Image(systemName: "xmark")
                    .font(cf(13, .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Close Web Artifacts")
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                availabilityPicker
                    .frame(width: 250)
                Spacer(minLength: 12)
                searchField
                    .frame(width: 330)
                sortMenu
                refreshButton
            }

            VStack(spacing: 10) {
                searchField
                    .frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    availabilityPicker
                        .frame(minWidth: 230, maxWidth: .infinity)
                    sortMenu
                    refreshButton
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    private var availabilityPicker: some View {
        HStack(spacing: 3) {
            ForEach(Availability.allCases) { option in
                availabilityButton(option)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
        )
    }

    private func availabilityButton(_ option: Availability) -> some View {
        let selected = availability == option
        return Button {
            withAnimation(.easeOut(duration: 0.14)) { availability = option }
        } label: {
            Text(option.rawValue)
                .font(cf(11.5, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 27)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Theme.selection : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(option.rawValue.lowercased()) web artifacts")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    if sortOrder == order { Label(order.rawValue, systemImage: "checkmark") }
                    else { Text(order.rawValue) }
                }
            }
        } label: {
            Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                .font(cf(11, .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var refreshButton: some View {
        Button {
            Task { await webArtifacts.refresh(machines: state.machines) }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(cf(11, .semibold))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .disabled(webArtifacts.isRefreshing)
        .help("Refresh Web Artifacts")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(cf(10.5))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search name, panel, machine, path, or URL", text: $query)
                .textFieldStyle(.plain)
                .font(cf(12.5))
                .foregroundStyle(Theme.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(cf(10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        )
    }

    @ViewBuilder
    private var content: some View {
        if webArtifacts.isRefreshing && webArtifacts.items.isEmpty {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        } else if visibleItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 370), spacing: 16)], spacing: 16) {
                    ForEach(visibleItems) { item in recipeCard(item) }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: query.isEmpty ? "globe.desk" : "magnifyingglass")
                .font(cf(31, .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(query.isEmpty ? "No web artifacts saved" : "No matching web artifacts")
                .font(cf(16, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(query.isEmpty
                 ? "An agent can save one without starting it using `ut web-artifacts add`."
                 : "Try another name, panel, machine, path, or URL.")
                .font(cf(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if query.isEmpty {
                Button("Copy CLI example") { copy(Self.cliExample) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func recipeCard(_ item: WebArtifactItem) -> some View {
        let launchState = webArtifacts.state(for: item)
        let color = statusColor(item, state: launchState)
        return VStack(alignment: .leading, spacing: 0) {
            WebArtifactRouteHeader(color: color)
                .frame(height: 74)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 7) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(item.reachable ? launchState.label.uppercased() : "MACHINE OFFLINE")
                            .font(cf(9.5, .bold))
                            .tracking(0.85)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(relativeTime(item.recipe.updatedAt))
                            .font(cf(9.5, .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(12)
                }

            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.recipe.name)
                        .font(cf(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Label(endpointLabel(item.recipe.url), systemImage: "link")
                        .font(cf(10.5, .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    metadataRow(icon: "terminal", text: item.recipe.sessionName)
                    metadataRow(icon: "desktopcomputer", text: item.recipe.machineName)
                    metadataRow(icon: "folder", text: item.recipe.workingDirectory, middle: true)
                }

                HStack(spacing: 8) {
                    Button { launch(item) } label: {
                        HStack(spacing: 7) {
                            if launchState == .starting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: launchState == .ready ? "arrow.up.right" : "play.fill")
                                    .font(cf(9, .bold))
                            }
                            Text(launchState == .ready ? "Open" : "Launch")
                                .font(cf(11, .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 31)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(item.reachable ? Theme.appBackground : Theme.textTertiary)
                    .background(RoundedRectangle(cornerRadius: 8).fill(item.reachable ? Theme.accent : Theme.border))
                    .disabled(!item.reachable || launchState == .starting)

                    Menu {
                        Button("Copy command") { copy(item.recipe.command) }
                        Button("Copy working directory") { copy(item.recipe.workingDirectory) }
                        Button("Copy URL") { copy(item.recipe.url) }
                        Divider()
                        Button("Stop service") { Task { await webArtifacts.stop(item) } }
                            .disabled(!item.reachable)
                        Button("Delete saved recipe…", role: .destructive) { deleteCandidate = item }
                            .disabled(!item.reachable)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(cf(11, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 31, height: 31)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(13)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(item.recipe.command)
    }

    private func metadataRow(icon: String, text: String, middle: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(cf(9.5, .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 13)
            Text(text)
                .font(cf(10.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(middle ? .middle : .tail)
        }
    }

    private func launch(_ item: WebArtifactItem) {
        Task {
            guard let target = await webArtifacts.start(item),
                  let machine = state.machines.first(where: { $0.id == item.machineID }) else { return }
            dashboards.openLocalhost(
                on: machine,
                port: target.port,
                path: target.path,
                scheme: target.scheme
            )
            openWindow(id: "dashboards")
        }
    }

    private func statusColor(_ item: WebArtifactItem, state: WebArtifactLaunchState) -> Color {
        guard item.reachable else { return Theme.textTertiary }
        switch state {
        case .saved: return Theme.accent
        case .starting: return Theme.waiting
        case .ready: return Theme.attached
        case .failed: return Theme.unreachable
        }
    }

    private func endpointLabel(_ raw: String) -> String {
        if raw.contains("{port}") { return "localhost · automatic port" }
        guard let components = URLComponents(string: raw) else { return raw }
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path == "/" ? "" : components.path
        return "localhost" + port + path
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private static let cliExample = """
    ut web-artifacts add "Project dashboard" --cwd /absolute/project/path --port auto --url 'http://localhost:{port}/' --command 'exec python dashboard.py --port {port}'
    """
}

/// A compact route diagram distinguishes executable web recipes from the
/// thumbnail-based file Artifact gallery without inventing a fake webpage.
private struct WebArtifactRouteHeader: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let y = size.height * 0.67
            var route = Path()
            route.move(to: CGPoint(x: 16, y: y))
            route.addLine(to: CGPoint(x: size.width * 0.44, y: y))
            route.addCurve(
                to: CGPoint(x: size.width - 16, y: size.height * 0.31),
                control1: CGPoint(x: size.width * 0.61, y: y),
                control2: CGPoint(x: size.width * 0.67, y: size.height * 0.31)
            )
            context.stroke(route, with: .color(color.opacity(0.42)), style: StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
            for point in [
                CGPoint(x: 16, y: y),
                CGPoint(x: size.width * 0.44, y: y),
                CGPoint(x: size.width - 16, y: size.height * 0.31),
            ] {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
        .background(
            LinearGradient(
                colors: [Theme.surface, color.opacity(0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .allowsHitTesting(false)
    }
}
