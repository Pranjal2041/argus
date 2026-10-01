import SwiftUI

/// Machines and their sessions: a pinned "Needs attention" strip, live state
/// dots, create / rename / hide / kill, and toggles for background and hidden
/// sessions.
struct MachinesView: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: ThemeStore
    @State private var newSessionOn: Machine?
    @State private var newName = ""
    @State private var newDir = ""
    @State private var editing: SessionRoute?
    @State private var editName = ""
    @State private var actionError: String?
    @State private var addingMachine = false
    @State private var machineHost = ""

    var body: some View {
        List {
            if let e = fleet.hubError { Section { Text(e).font(.footnote).foregroundStyle(.orange) } }
            let waiting = fleet.needsAttention
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting, id: \.1.id) { m, s in
                        Button { router.openTerminal(m, s) } label: {
                            HStack {
                                Circle().fill(theme.palette.waitingColor).frame(width: 7, height: 7)
                                Text(s.name).foregroundStyle(.primary)
                                Spacer()
                                Text(m.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Label("Needs attention · \(waiting.count)", systemImage: "bell.badge").foregroundStyle(theme.palette.waitingColor)
                }
                .listRowBackground(theme.palette.waitingColor.opacity(0.07))
            }
            ForEach(fleet.machines) { m in
                Section {
                    ForEach(fleet.sessions(on: m)) { s in sessionRow(m, s) }
                    if fleet.sessions(on: m).isEmpty {
                        Text(fleet.reachable.contains(m.id) ? "No sessions" : "Unreachable").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Circle().fill(fleet.reachable.contains(m.id) ? theme.palette.milestoneColor : theme.palette.badColor).frame(width: 7, height: 7)
                        Text(m.name)
                        if m.isHub { Text("hub").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Button { newName = ""; newDir = ""; newSessionOn = m } label: { Image(systemName: "plus.circle") }
                            .disabled(!fleet.reachable.contains(m.id))
                            .accessibilityLabel("New session on \(m.name)")
                    }
                }
            }
        }
        .navigationTitle("Machines")
        .refreshable { await fleet.refreshNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show agent sessions", isOn: $fleet.showAgentSessions)
                    if fleet.hasHiddenSessions { Toggle("Show hidden", isOn: $fleet.showHidden) }
                    Button { machineHost = ""; addingMachine = true } label: { Label("Add machine…", systemImage: "plus") }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        .sheet(item: $newSessionOn) { m in
            NavigationStack {
                Form {
                    TextField("name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("folder (optional)", text: $newDir).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                .navigationTitle("New session on \(m.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { newSessionOn = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            newSessionOn = nil
                            act {
                                try await fleet.createSession(on: m, name: name, dir: newDir.trimmingCharacters(in: .whitespaces))
                                if let s = fleet.session(on: m, named: name) { router.openTerminal(m, s) }
                            }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Rename session", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("name", text: $editName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") {
                guard let r = editing else { return }
                let to = editName.trimmingCharacters(in: .whitespaces)
                if !to.isEmpty, to != r.session.name { act { try await fleet.renameSession(r.session, on: r.machine, to: to) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Add machine", isPresented: $addingMachine) {
            TextField("ut-host.your-tailnet.ts.net", text: $machineHost).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") { act { try await fleet.addManualBroker(machineHost) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Tailnet hostname of a machine running the Argus broker.") }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    @ViewBuilder private func sessionRow(_ m: Machine, _ s: SessionInfo) -> some View {
        Button { router.openTerminal(m, s) } label: {
            HStack {
                Circle().fill(dot(s.state)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(s.name).foregroundStyle(s.hidden ? .secondary : .primary)
                        if s.agent { Image(systemName: "gearshape").font(.caption2).foregroundStyle(.secondary) }
                        if s.hidden { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if let p = s.path, !p.isEmpty {
                        Text(p).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer()
                if let a = s.activity, a > 0 {
                    Text(Date(timeIntervalSince1970: TimeInterval(a)), style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) { act { try await fleet.killSession(s, on: m) } } label: { Label("Kill", systemImage: "xmark") }
            Button { act { try await fleet.setHidden(s, on: m, hidden: !s.hidden) } } label: {
                Label(s.hidden ? "Unhide" : "Hide", systemImage: s.hidden ? "eye" : "eye.slash")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button { editName = s.name; editing = SessionRoute(machine: m, session: s) } label: { Label("Rename", systemImage: "pencil") }
            Button { act { try await fleet.setHidden(s, on: m, hidden: !s.hidden) } } label: {
                Label(s.hidden ? "Restore panel (unhide)" : "Hide panel", systemImage: "eye.slash")
            }
            if let p = s.path, !p.isEmpty {
                Button { router.openFiles(m, path: p) } label: { Label("Open folder", systemImage: "folder") }
            }
            Button(role: .destructive) { act { try await fleet.killSession(s, on: m) } } label: { Label("Kill", systemImage: "xmark.octagon") }
        }
    }

    private func dot(_ state: String?) -> Color {
        switch state {
        case "waiting": return theme.palette.waitingColor
        case "working": return theme.palette.workingColor
        default: return theme.palette.idleColor
        }
    }

    private func act(_ body: @escaping () async throws -> Void) {
        Task { do { try await body() } catch { actionError = error.localizedDescription } }
    }
}
