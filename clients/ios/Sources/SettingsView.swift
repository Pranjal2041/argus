import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var theme: ThemeStore
    @State private var address = ""
    @State private var notifications = AttentionNotifications.shared.enabled
    @State private var journal = JournalCapture.shared.enabled
    @State private var addError: String?
    @State private var newHost = ""

    var body: some View {
        Form {
            if fleet.isDemo {
                Section {
                    Button("Connect my own Mac") { fleet.hubAddress = "" }
                } header: { Text("Demo") } footer: {
                    Text("You're exploring a sample fleet. Connect your Mac to see your real machines.")
                }
            }
            Section {
                TextField("hub", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Save") {
                    fleet.hubAddress = address.trimmingCharacters(in: .whitespaces)
                    Task { await fleet.refreshNow() }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || address == fleet.hubAddress)
            } header: { Text("Hub (your Mac)") } footer: {
                Text("Argus asks this broker for the other machines on your tailnet. It is also the sync host for Notes, Todos, Workflows, the Activity Journal and Weekly Progress.")
            }

            Section {
                ForEach(fleet.manualBrokers, id: \.self) { h in Text(h).font(.body.monospaced()) }
                    .onDelete { idx in idx.map { fleet.manualBrokers[$0] }.forEach(fleet.removeManualBroker) }
                HStack {
                    TextField("ut-host.your-tailnet.ts.net", text: $newHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") {
                        Task {
                            do { try await fleet.addManualBroker(newHost); newHost = ""; addError = nil }
                            catch { addError = "No broker at \(newHost):8722" }
                        }
                    }
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
            } header: { Text("Machines added by hand") } footer: {
                Text("For brokers the hub can't see. They're never pruned by discovery.")
            }

            Section("Theme") {
                ForEach(ThemePalette.all) { p in
                    Button { theme.palette = p } label: {
                        HStack {
                            HStack(spacing: 3) {
                                ForEach([p.accent, p.milestone, p.working, p.waiting, p.unseen, p.bad], id: \.self) { c in
                                    Circle().fill(ThemePalette.color(c)).frame(width: 10, height: 10)
                                }
                            }
                            .padding(5).background(ThemePalette.color(p.bg), in: Capsule())
                            Text(p.name).foregroundStyle(.primary)
                            Spacer()
                            if p.id == theme.palette.id { Image(systemName: "checkmark").foregroundStyle(theme.palette.accentColor) }
                        }
                    }
                }
            }

            Section {
                Toggle("Notify when an agent needs me", isOn: $notifications)
                    .onChange(of: notifications) { _, v in AttentionNotifications.shared.enabled = v }
            } footer: {
                Text("Sessions that start waiting on you and new Lab requests. While Argus is in the background, iOS checks only occasionally.")
            }

            Section {
                Toggle("Record typed messages in the Activity Journal", isOn: $journal)
                    .onChange(of: journal) { _, v in JournalCapture.shared.enabled = v }
            } footer: {
                Text("What you type into terminals is sent to your Mac's journal for Wrapped and the Activity Ledger. Text that never appears on screen (like a password) is recorded only as a character count.")
            }

            Section("Sessions") {
                Toggle("Show agent sessions", isOn: $fleet.showAgentSessions)
            }

            Section("Status") {
                LabeledContent("Machines", value: "\(fleet.machines.count)")
                LabeledContent("Reachable", value: "\(fleet.reachable.count)")
                LabeledContent("Sync host", value: fleet.syncHost?.name ?? "—")
                if let t = fleet.lastRefresh {
                    LabeledContent("Updated", value: t.formatted(date: .omitted, time: .standard))
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear { address = fleet.hubAddress }
    }
}
