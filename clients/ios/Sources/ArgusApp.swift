import SwiftUI

@main
struct ArgusApp: App {
    @StateObject private var fleet = FleetStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(fleet)
                .preferredColorScheme(.dark)
                .onAppear { fleet.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { fleet.start() } else if phase == .background { fleet.stop() }
                }
        }
    }
}

struct SessionRoute: Hashable {
    let machine: Machine
    let session: SessionInfo
}

struct RootView: View {
    @EnvironmentObject var fleet: FleetStore

    var body: some View {
        if fleet.isConfigured {
            TabView {
                NavigationStack { CommandCenterView() }
                    .tabItem { Label("Command Center", systemImage: "rectangle.stack") }
                NavigationStack { MachinesView() }
                    .tabItem { Label("Machines", systemImage: "server.rack") }
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
        } else {
            SetupView()
        }
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

// MARK: Command Center

struct CommandCenterView: View {
    @EnvironmentObject var fleet: FleetStore

    var body: some View {
        List {
            if let e = fleet.hubError { Section { Text(e).font(.footnote).foregroundStyle(.orange) } }
            ForEach(AttentionSection.allCases) { section in
                let cards = fleet.cards.filter { $0.section == section }
                if !cards.isEmpty {
                    Section(section.title + " · \(cards.count)") {
                        ForEach(cards) { card in
                            NavigationLink(value: SessionRoute(machine: card.machine, session: card.session)) {
                                CardRow(card: card)
                            }
                        }
                    }
                }
            }
            if fleet.cards.isEmpty && fleet.hubError == nil {
                Text(fleet.machines.isEmpty ? "Looking for machines…" : "No sessions yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Command Center")
        .navigationDestination(for: SessionRoute.self) { TerminalScreen(machine: $0.machine, session: $0.session) }
        .refreshable { await fleet.refreshNow() }
    }
}

struct CardRow: View {
    let card: FleetStore.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(card.session.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Text(card.machine.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summary = card.item?.summary, !summary.isEmpty {
                Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            if let look = card.item?.lookAtThis, !look.isEmpty {
                Text(look).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch card.section {
        case .needsYou: return .orange
        case .working: return .green
        case .idle: return .gray
        }
    }
}

// MARK: Machines

struct MachinesView: View {
    @EnvironmentObject var fleet: FleetStore
    @State private var newSessionOn: Machine?
    @State private var newName = ""
    @State private var actionError: String?

    var body: some View {
        List {
            if let e = fleet.hubError { Section { Text(e).font(.footnote).foregroundStyle(.orange) } }
            ForEach(fleet.machines) { m in
                Section {
                    ForEach(fleet.sessions[m.id] ?? []) { s in
                        NavigationLink(value: SessionRoute(machine: m, session: s)) {
                            HStack {
                                Circle().fill(dot(s.state)).frame(width: 7, height: 7)
                                VStack(alignment: .leading) {
                                    Text(s.name)
                                    if let p = s.path, !p.isEmpty {
                                        Text(p).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                }
                            }
                        }
                        .swipeActions {
                            Button("Kill", role: .destructive) {
                                Task {
                                    do { try await fleet.killSession(s, on: m) } catch { actionError = error.localizedDescription }
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Circle().fill(fleet.reachable.contains(m.id) ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(m.name)
                        Spacer()
                        Button { newName = ""; newSessionOn = m } label: { Image(systemName: "plus") }
                            .disabled(!fleet.reachable.contains(m.id))
                    }
                }
            }
        }
        .navigationTitle("Machines")
        .navigationDestination(for: SessionRoute.self) { TerminalScreen(machine: $0.machine, session: $0.session) }
        .refreshable { await fleet.refreshNow() }
        .alert("New session", isPresented: Binding(get: { newSessionOn != nil }, set: { if !$0 { newSessionOn = nil } })) {
            TextField("name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") {
                guard let m = newSessionOn else { return }
                let name = newName.trimmingCharacters(in: .whitespaces)
                Task {
                    do { try await fleet.createSession(on: m, name: name) } catch { actionError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(newSessionOn.map { "On \($0.name)" } ?? "")
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private func dot(_ state: String?) -> Color {
        switch state {
        case "waiting": return .orange
        case "working": return .green
        default: return .gray
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var fleet: FleetStore
    @State private var address = ""

    var body: some View {
        Form {
            Section {
                TextField("hub", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Save") {
                    fleet.hubAddress = address.trimmingCharacters(in: .whitespaces)
                    Task { await fleet.refreshNow() }
                }
            } header: { Text("Hub (your Mac)") } footer: {
                Text("Argus asks this broker for the other machines on your tailnet.")
            }
            Section("Status") {
                LabeledContent("Machines", value: "\(fleet.machines.count)")
                LabeledContent("Reachable", value: "\(fleet.reachable.count)")
                if let t = fleet.lastRefresh {
                    LabeledContent("Updated", value: t.formatted(date: .omitted, time: .standard))
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear { address = fleet.hubAddress }
    }
}
