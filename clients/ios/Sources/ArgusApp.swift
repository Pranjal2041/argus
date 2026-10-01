import SwiftUI

@main
struct ArgusApp: App {
    @StateObject private var fleet = FleetStore()
    @StateObject private var router = AppRouter()
    @StateObject private var lab = LabStore()
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var weekly = WeeklyProgressStore()
    @StateObject private var theme = ThemeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(fleet)
                .environmentObject(router)
                .environmentObject(lab)
                .environmentObject(workspace)
                .environmentObject(weekly)
                .environmentObject(theme)
                .tint(theme.palette.accentColor)
                .preferredColorScheme(theme.palette.isLight ? .light : .dark)
                .onAppear {
                    AttentionNotifications.shared.attach(fleet: fleet, lab: lab, router: router)
                    lab.start(fleet: fleet)
                    workspace.start(fleet: fleet, router: router)
                    weekly.start(fleet: fleet)
                    JournalCapture.shared.attach(fleet: fleet)
                    fleet.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: fleet.start(); AttentionNotifications.shared.clearBadgeIfNeeded()
                    case .background: BackgroundRefresh.remember(fleet); fleet.stop(); BackgroundRefresh.schedule()
                    default: break
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { await BackgroundRefresh.run() }
    }
}

struct RootView: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var lab: LabStore

    var body: some View {
        if fleet.isConfigured {
            TabView(selection: $router.tab) {
                NavigationStack(path: $router.commandCenterPath) { CommandCenterView().argusDestinations() }
                    .tabItem { Label("Command", systemImage: "rectangle.stack") }
                    .badge(fleet.needsAttention.count + lab.attention.count)
                    .tag(AppRouter.Tab.commandCenter)
                NavigationStack(path: $router.machinesPath) { MachinesView().argusDestinations() }
                    .tabItem { Label("Machines", systemImage: "server.rack") }
                    .tag(AppRouter.Tab.machines)
                NavigationStack(path: $router.filesPath) { FilesTab().argusDestinations() }
                    .tabItem { Label("Files", systemImage: "folder") }
                    .tag(AppRouter.Tab.files)
                NavigationStack(path: $router.labPath) { LabView().argusDestinations() }
                    .tabItem { Label("Lab", systemImage: "flask") }
                    .badge(lab.attention.count)
                    .tag(AppRouter.Tab.lab)
                NavigationStack(path: $router.morePath) { MoreView().argusDestinations() }
                    .tabItem { Label("More", systemImage: "ellipsis.circle") }
                    .tag(AppRouter.Tab.more)
            }
        } else {
            SetupView()
        }
    }
}

struct MoreView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { NotesView().argusDestinations() } label: { Label("Notes", systemImage: "note.text") }
                NavigationLink { TodoMapsView().argusDestinations() } label: { Label("Todo Maps", systemImage: "checklist") }
                NavigationLink { WorkflowsView().argusDestinations() } label: { Label("Workflows", systemImage: "play.rectangle") }
                NavigationLink { WeeklyProgressView().argusDestinations() } label: { Label("Weekly Progress", systemImage: "chart.bar.doc.horizontal") }
            }
            Section {
                NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gear") }
            }
        }
        .navigationTitle("More")
    }
}

// MARK: Setup

struct SetupView: View {
    @EnvironmentObject var fleet: FleetStore
    @Environment(\.openURL) private var openURL
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "eye.circle.fill").font(.system(size: 52)).foregroundStyle(.tint)
                        Text("Argus").font(.largeTitle.bold())
                        Text("Every agent, on every machine — from your phone.").foregroundStyle(.secondary)
                    }
                    step(1, "Join your tailnet",
                         "Install Tailscale on this iPhone and sign in with the same account as your Mac.") {
                        Button { openURL(URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!) } label: {
                            Label("Get Tailscale", systemImage: "arrow.down.app")
                        }
                        .buttonStyle(.bordered)
                    }
                    step(2, "Connect to your Mac",
                         "Enter your Mac's Tailscale machine name (shown in the Tailscale app) or its 100.x address. Argus finds your other machines through it.") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("macbook-pro or 100.x.y.z", text: $address)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .focused($focused)
                                .submitLabel(.go)
                                .onSubmit { Task { await connect() } }
                                .padding(12).background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                            Button { Task { await connect() } } label: {
                                HStack {
                                    if checking { ProgressView().controlSize(.small) }
                                    Text(checking ? "Connecting…" : "Connect").frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
                            if let error {
                                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Just looking?").font(.headline)
                        Text("Explore Argus with a sample fleet — three machines with agents working, waiting and finished. Nothing leaves this phone.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            fleet.hubAddress = DemoFleet.hubHost
                            Task { await fleet.refreshNow() }
                        } label: { Label("Explore the demo", systemImage: "sparkles") }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func step<Content: View>(_ n: Int, _ title: String, _ detail: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.headline).frame(width: 28, height: 28).background(Circle().fill(.tint.opacity(0.2)))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                content()
            }
        }
    }

    private func connect() async {
        checking = true
        defer { checking = false }
        do {
            _ = try await fleet.resolveHub(address)
            fleet.hubAddress = address.trimmingCharacters(in: .whitespaces)
            await fleet.refreshNow()
            if AttentionNotifications.shared.enabled { AttentionNotifications.shared.requestAuthorization() }
        } catch {
            self.error = "Couldn't reach an Argus broker at \(address). Check that Tailscale is connected on this iPhone and Argus is running on your Mac. (\(error.localizedDescription))"
        }
    }
}
