import SwiftUI

struct CredentialVaultView: View {
    @EnvironmentObject private var vault: CredentialVaultStore
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var search = ""
    @State private var selection: UUID?
    @State private var editing: CredentialVaultEntry?
    @State private var adding = false
    @State private var deleting: CredentialVaultEntry?

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var filtered: [CredentialVaultEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return vault.entries }
        return vault.entries.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.group.localizedCaseInsensitiveContains(query)
        }
    }

    private var selected: CredentialVaultEntry? {
        vault.entries.first { $0.id == selection }
    }

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.border)
                HStack(spacing: 0) {
                    credentialList
                    Divider().overlay(Theme.border)
                    detail
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $adding) {
            CredentialEditorView(entry: nil).environmentObject(vault)
        }
        .sheet(item: $editing) { entry in
            CredentialEditorView(entry: entry).environmentObject(vault)
        }
        .alert("Credential Vault", isPresented: Binding(
            get: { vault.errorMessage != nil },
            set: { if !$0 { vault.errorMessage = nil } }
        )) {
            Button("OK") { vault.errorMessage = nil }
        } message: {
            Text(vault.errorMessage ?? "")
        }
        .alert("Delete credential?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let entry = deleting else { return }
                do { try vault.delete(entry) } catch { vault.errorMessage = error.localizedDescription }
                deleting = nil
            }
        } message: {
            Text("\(deleting?.name ?? "This credential") and its saved password will be removed from this Mac.")
        }
        .onAppear {
            if selection == nil { selection = vault.entries.first?.id }
        }
        .onChange(of: vault.entries) { entries in
            if selection == nil || !entries.contains(where: { $0.id == selection }) {
                selection = entries.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14 * uiScale) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: "key.horizontal.fill")
                    .font(cf(17, .semibold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 38 * uiScale, height: 38 * uiScale)
            VStack(alignment: .leading, spacing: 1) {
                Text("Credential Vault").font(cf(21, .bold)).foregroundStyle(Theme.textPrimary)
                Text("Secrets stay on this Mac. Agents receive permission, never passwords.")
                    .font(cf(11.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button {
                vault.setAllowInUnattendedMode(!vault.allowInUnattendedMode)
            } label: {
                HStack(spacing: 7 * uiScale) {
                    Image(systemName: vault.allowInUnattendedMode ? "moon.stars.fill" : "moon.stars")
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Unattended access").font(cf(11.5, .semibold))
                        Text(vault.allowInUnattendedMode ? "Enabled" : "Off")
                            .font(cf(9.5, .medium)).opacity(0.72)
                    }
                }
                .foregroundStyle(vault.allowInUnattendedMode ? Theme.waiting : Theme.textSecondary)
                .padding(.horizontal, 12 * uiScale).padding(.vertical, 7 * uiScale)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface.opacity(0.75)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                    vault.allowInUnattendedMode ? Theme.waiting.opacity(0.55) : Theme.border, lineWidth: 1
                ))
            }
            .buttonStyle(.plain)
            .help("When Argus Unattended Mode is on, verified panel agents may use saved credentials without waiting. Secrets remain on this Mac and remain available after its first unlock.")
            Button { adding = true } label: {
                Label("Add credential", systemImage: "plus")
            }
            .buttonStyle(AccentButtonStyle(scale: uiScale))
        }
        .padding(.horizontal, 24 * uiScale).padding(.vertical, 17 * uiScale)
    }

    private var credentialList: some View {
        VStack(spacing: 12 * uiScale) {
            HStack(spacing: 8 * uiScale) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search credentials", text: $search)
                    .textFieldStyle(.plain).font(cf(12.5)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 11 * uiScale).padding(.vertical, 9 * uiScale)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            if filtered.isEmpty {
                Spacer()
                Image(systemName: "key.slash").font(cf(28)).foregroundStyle(Theme.textTertiary)
                Text(search.isEmpty ? "No saved credentials" : "No matches")
                    .font(cf(12.5, .medium)).foregroundStyle(Theme.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5 * uiScale) {
                        ForEach(filtered) { entry in
                            Button { selection = entry.id } label: {
                                HStack(spacing: 10 * uiScale) {
                                    Circle().fill(Glass.tint(for: entry.group.isEmpty ? entry.name : entry.group))
                                        .frame(width: 7 * uiScale, height: 7 * uiScale)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).font(cf(13, .semibold)).foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1)
                                        Text(entry.displayGroup).font(cf(10.5)).foregroundStyle(Theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if selection == entry.id {
                                        Image(systemName: "chevron.right").font(cf(9, .bold)).foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(.horizontal, 11 * uiScale).padding(.vertical, 9 * uiScale)
                                .background(RoundedRectangle(cornerRadius: 8).fill(
                                    selection == entry.id ? Theme.accent.opacity(0.13) : Color.clear
                                ))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16 * uiScale)
        .frame(width: 260 * uiScale)
        .background(Theme.sidebarBackground.opacity(0.66))
    }

    @ViewBuilder private var detail: some View {
        if let entry = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 24 * uiScale) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(cf(26, .bold)).foregroundStyle(Theme.textPrimary)
                            Text(entry.displayGroup).font(cf(12, .medium)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("Edit") { editing = entry }.buttonStyle(GhostButtonStyle(scale: uiScale))
                        Button(role: .destructive) { deleting = entry } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(GhostButtonStyle(color: Theme.unreachable, scale: uiScale))
                    }

                    VStack(alignment: .leading, spacing: 13 * uiScale) {
                        Text("AVAILABLE FIELDS").font(cf(10.5, .bold)).tracking(1.3)
                            .foregroundStyle(Theme.textTertiary)
                        vaultField(icon: "person", name: "username", value: "Stored locally")
                        vaultField(icon: "key", name: "password", value: "••••••••••••")
                    }
                    .padding(18 * uiScale).glassCard(cornerRadius: 12, strong: true)

                    VStack(alignment: .leading, spacing: 10 * uiScale) {
                        HStack {
                            Text("RECENT ACCESS").font(cf(10.5, .bold)).tracking(1.3)
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Button("Forget saved approvals") { vault.revokeSavedPolicies() }
                                .buttonStyle(.plain).font(cf(10.5, .medium)).foregroundStyle(Theme.accent)
                        }
                        let events = vault.auditEvents.filter { $0.credentialName == entry.name }.prefix(8)
                        if events.isEmpty {
                            Text("No agent has used this credential yet.")
                                .font(cf(12)).foregroundStyle(Theme.textTertiary).padding(.vertical, 8)
                        } else {
                            ForEach(Array(events)) { event in
                                HStack(alignment: .firstTextBaseline, spacing: 10 * uiScale) {
                                    Circle().fill(event.action.contains("denied") ? Theme.unreachable : Theme.attached)
                                        .frame(width: 6 * uiScale, height: 6 * uiScale)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.action.capitalized).font(cf(11.5, .medium)).foregroundStyle(Theme.textPrimary)
                                        Text(event.caller).font(cf(10.5)).foregroundStyle(Theme.textTertiary)
                                    }
                                    Spacer()
                                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(cf(10, .regular)).foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.vertical, 4 * uiScale)
                            }
                        }
                    }
                }
                .padding(28 * uiScale)
            }
        } else {
            VStack(spacing: 12 * uiScale) {
                Image(systemName: "lock.shield").font(cf(42)).foregroundStyle(Theme.accent.opacity(0.8))
                Text("A quiet place for agent credentials").font(cf(18, .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Add a login once. Approve how long an agent may use it when requested.")
                    .font(cf(12)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 340 * uiScale)
                Button("Add first credential") { adding = true }
                    .buttonStyle(AccentButtonStyle(scale: uiScale))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func vaultField(icon: String, name: String, value: String) -> some View {
        HStack(spacing: 11 * uiScale) {
            Image(systemName: icon).frame(width: 18 * uiScale).foregroundStyle(Theme.accent)
            Text(name).font(cf(12, .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value).font(cf(11, .regular)).foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 3 * uiScale)
    }
}

struct CredentialEditorView: View {
    @EnvironmentObject private var vault: CredentialVaultStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    let entry: CredentialVaultEntry?
    @State private var name = ""
    @State private var group = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorText: String?

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry == nil ? "Add credential" : "Edit credential")
                    .font(cf(20, .bold)).foregroundStyle(Theme.textPrimary)
                Text("The password is encrypted by macOS and never returned to an agent.")
                    .font(cf(11)).foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: 12 * uiScale) {
                labeledField("Name", hint: "Research Gmail", text: $name)
                labeledField("Group", hint: "Research accounts (optional)", text: $group)
                labeledField("Username", hint: "name@example.com", text: $username)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Password").font(cf(10.5, .semibold)).foregroundStyle(Theme.textSecondary)
                    SecureField("Required", text: $password)
                        .textFieldStyle(.plain).font(cf(13)).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12 * uiScale).padding(.vertical, 10 * uiScale)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                }
            }
            if let errorText { Text(errorText).font(cf(11)).foregroundStyle(Theme.unreachable) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(AccentButtonStyle(enabled: !name.isEmpty && !password.isEmpty, scale: uiScale))
                    .disabled(name.isEmpty || password.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24 * uiScale)
        .frame(width: 460 * uiScale)
        .background(Theme.appBackground)
        .onAppear { load() }
    }

    private func labeledField(_ label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(cf(10.5, .semibold)).foregroundStyle(Theme.textSecondary)
            TextField(hint, text: text)
                .textFieldStyle(.plain).font(cf(13)).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12 * uiScale).padding(.vertical, 10 * uiScale)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func load() {
        guard let entry else { return }
        name = entry.name
        group = entry.group
        do {
            let secret = try vault.secret(for: entry)
            username = secret.username
            password = secret.password
        } catch { errorText = error.localizedDescription }
    }

    private func save() {
        do {
            try vault.save(id: entry?.id, name: name, group: group,
                           username: username, password: password)
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

struct CredentialApprovalSheet: View {
    @EnvironmentObject private var vault: CredentialVaultStore
    @ObservedObject var request: CredentialApprovalRequest
    @AppStorage("ut.uiScale") private var uiScale = 1.0

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 19 * uiScale) {
            HStack(alignment: .top, spacing: 13 * uiScale) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.waiting.opacity(0.15))
                    Image(systemName: "key.horizontal.fill").font(cf(18, .bold)).foregroundStyle(Theme.waiting)
                }
                .frame(width: 42 * uiScale, height: 42 * uiScale)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Credential requested").font(cf(20, .bold)).foregroundStyle(Theme.textPrimary)
                    Text(request.caller.displayName).font(cf(11.5, .medium)).foregroundStyle(Theme.textSecondary)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.entry.name).font(cf(16, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(request.entry.displayGroup).font(cf(10.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text("Password stays on this Mac")
                    .font(cf(10.5, .medium)).foregroundStyle(Theme.attached)
            }
            .padding(14 * uiScale).glassCard(cornerRadius: 11, strong: true)

            VStack(alignment: .leading, spacing: 9 * uiScale) {
                Text("ACCESS").font(cf(10, .bold)).tracking(1.2).foregroundStyle(Theme.textTertiary)
                Picker("", selection: $request.duration) {
                    ForEach(CredentialGrantDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }

            VStack(alignment: .leading, spacing: 9 * uiScale) {
                Text("SCOPE").font(cf(10, .bold)).tracking(1.2).foregroundStyle(Theme.textTertiary)
                Picker("", selection: $request.scope) {
                    Text("This credential").tag(CredentialGrantScope.credential)
                    if !request.entry.group.isEmpty {
                        Text("All in \"\(request.entry.group)\"").tag(CredentialGrantScope.group)
                    }
                    Text("Entire Argus Vault").tag(CredentialGrantScope.vault)
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }

            if !request.domain.isEmpty {
                Toggle("Restrict to \(request.domain)", isOn: $request.restrictToDomain)
                    .font(cf(11.5)).foregroundStyle(Theme.textSecondary)
                Text("Off by default so sign-in redirects and related sites keep working.")
                    .font(cf(10)).foregroundStyle(Theme.textTertiary)
            }

            HStack {
                Button("Deny") { vault.denyPending() }
                    .buttonStyle(GhostButtonStyle(color: Theme.textSecondary, scale: uiScale))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow") { vault.approvePending() }
                    .buttonStyle(AccentButtonStyle(scale: uiScale))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(25 * uiScale)
        .frame(width: 480 * uiScale)
        .background(Theme.appBackground)
    }
}
