import SwiftUI

@available(macOS 14.0, *)
struct ConnectionEditor: View {
    @State var draft: ConnectionDraft
    @Bindable var store: UsageStore

    private var busy: Bool { store.savingConnection || store.refreshing || store.loginSourceID != nil }
    private var actionTitle: String {
        if draft.startsCodexLogin { return "Sign in with ChatGPT" }
        if draft.startsClaudeLogin { return "Sign in with Claude" }
        return draft.sourceID == nil ? (draft.integration.category == .devices ? "Connect device" : "Connect account") : "Save changes"
    }

    var body: some View {
        SourceCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.sourceID == nil ? "Connect an account or device" : "Edit \(draft.integration.name) connection")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Set up and manage your connections here. No configuration file needed.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(Palette.secondary).disabled(store.savingConnection)
                        .accessibilityLabel("Cancel connection setup")
                }

                if draft.sourceID == nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(IntegrationID.allCases) { integration in
                            Button {
                                draft.integration = integration
                                draft.credentials = [:]
                                store.connectionSaveError = nil
                            } label: {
                                HStack(spacing: 10) {
                                    SourceIcon(integration: integration, size: 19)
                                    Text(integration.name).font(.system(size: 12, weight: .medium))
                                    Spacer(minLength: 0)
                                    if draft.integration == integration { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.blue) }
                                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(draft.integration == integration ? Palette.blue.opacity(0.08) : Palette.inset)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(draft.integration == integration ? Palette.blue : Palette.border, lineWidth: 1))
                            }.buttonStyle(.plain).accessibilityIdentifier("choose-provider-\(integration.rawValue)")
                        }
                    }
                }

                InfoNote(text: draft.integration.connectionHelp)
                HStack(alignment: .top, spacing: 20) {
                    field("Connection name") {
                        TextField("Personal, Work, or a name you recognize", text: $draft.label)
                            .accessibilityIdentifier("connection-label")
                    }
                    if draft.integration == .modal {
                        field("Modal environment") { TextField("main", text: $draft.environment).accessibilityIdentifier("connection-environment") }
                    }
                    if [.daytona, .modal, .openaiAPI].contains(draft.integration) {
                        field("Monthly budget · USD, optional") {
                            TextField("No budget", text: $draft.budget).accessibilityIdentifier("connection-budget")
                        }.frame(maxWidth: 230)
                    }
                }

                if !draft.integration.credentialFields.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if draft.hasSavedCredentials {
                            Label("Credentials are already configured. Leave all key fields blank to keep them, or enter a replacement.", systemImage: "lock.shield")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                        HStack(alignment: .top, spacing: 20) {
                            ForEach(draft.integration.credentialFields) { credential in
                                field(credential.title) {
                                    SecureField(draft.hasSavedCredentials ? "Unchanged" : credential.title,
                                                text: Binding(get: { draft.credentials[credential.id] ?? "" }, set: { draft.credentials[credential.id] = $0 }))
                                        .font(.system(size: 12, design: .monospaced))
                                        .accessibilityIdentifier("credential-\(credential.id)")
                                }
                            }
                        }
                    }
                }

                if draft.integration == .codex {
                    Toggle("Use an existing local Codex profile instead", isOn: $draft.useExistingCodexProfile)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                    if draft.useExistingCodexProfile {
                        field("Codex profile folder") { TextField("/Users/you/.codex", text: $draft.codexHome) }
                    } else {
                        Picker("Sign-in method", selection: $draft.codexLoginMethod) {
                            ForEach(CodexLoginMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).frame(maxWidth: 330).accessibilityIdentifier("codex-login-method")
                        Label(draft.codexLoginMethod == .browser ? "Opens UT Browser inside Argus. You can also copy the sign-in link." : "Shows a link and a one-time code here. No browser opens automatically.", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        if draft.codexLoginMethod == .deviceCode {
                            Text("Device-code login must be enabled in your ChatGPT security settings or workspace permissions.")
                                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                if draft.integration == .windowsStorage {
                    field("UT machine name") { TextField("DESKTOP-EXAMPLE", text: $draft.host).accessibilityIdentifier("connection-host") }
                }
                if draft.integration == .macStorage {
                    field("Volume path · one per line") { TextField("/System/Volumes/Data", text: $draft.mountPath, axis: .vertical).lineLimit(1...3) }
                }
                if draft.sourceID != nil {
                    Toggle("Enabled on dashboard", isOn: $draft.enabled).toggleStyle(.checkbox).font(.system(size: 12))
                }
                if let error = store.connectionSaveError { InfoNote(text: error, warning: true).accessibilityIdentifier("connection-error") }

                HStack(spacing: 12) {
                    Label(draft.integration.credentialFields.isEmpty ? "Read-only usage access" : "New keys are saved securely in macOS Keychain", systemImage: "lock.shield")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Spacer()
                    if store.savingConnection { ProgressView().controlSize(.small) }
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).disabled(store.savingConnection)
                    Button(actionTitle) { Task { await store.saveConnection(draft) } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("save-connection")
                }
            }
        }.accessibilityIdentifier("connection-editor")
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
            content().textFieldStyle(.roundedBorder).controlSize(.large)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func dismiss() {
        draft.credentials.removeAll()
        store.connectionDraft = nil
        store.connectionSaveError = nil
    }
}
