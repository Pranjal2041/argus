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
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("macbook-pro or 100.x.y.z", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(checking ? "Connecting…" : "Connect") { Task { await connect() } }
                        .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Your Mac's tailnet name")
                } footer: {
                    Text("Argus on iPhone uses the Tailscale app to join your tailnet. Install Tailscale, sign in to the same tailnet as your Mac, then enter your Mac's Tailscale machine name (or its 100.x address). Argus finds your other machines through it.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Argus")
        }
    }

    private func connect() async {
        checking = true
        defer { checking = false }
        do {
            _ = try await fleet.resolveHub(address)
            fleet.hubAddress = address.trimmingCharacters(in: .whitespaces)
            await fleet.refreshNow()
        } catch {
            self.error = "Couldn't reach an Argus broker at \(address): \(error.localizedDescription)"
        }
    }
}
