import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct ConnectionsView: View {
    @Bindable var store: UsageStore
    @State private var removing: SourceConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = store.configurationError { InfoNote(text: message, warning: true) }
            if let draft = store.connectionDraft { ConnectionEditor(draft: draft, store: store).id(draft.id) }
            if let message = store.loginMessage {
                VStack(alignment: .leading, spacing: 12) {
                  HStack {
                    if store.loginSourceID != nil { ProgressView().controlSize(.small) }
                    Text(message).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    if store.loginSourceID != nil {
                        Button("Cancel sign-in") { store.cancelLogin() }.buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("cancel-account-sign-in")
                    }
                  }
                  if let instructions = store.loginInstructions {
                    HStack(spacing: 12) {
                        if let code = instructions.userCode {
                            Text(code).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Button("Copy code") { copy(code) }.buttonStyle(SecondaryButtonStyle())
                        }
                        Link(instructions.userCode == nil ? "Open sign-in page" : "Open authorization page", destination: instructions.url)
                            .font(.system(size: 12))
                            .accessibilityIdentifier("open-account-sign-in")
                        Button("Copy link") { copy(instructions.url.absoluteString) }.buttonStyle(SecondaryButtonStyle())
                    }
                    if instructions.userCode != nil {
                        Text(instructions.url.absoluteString).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                  }
                  if store.claudeLoginFlow != nil || (store.remoteLoginIntegration == "claude" && store.loginSourceID != nil) {
                    HStack(spacing: 12) {
                        SecureField("Complete authorization code (code#state)", text: $store.claudeAuthorizationCode)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("claude-authorization-code")
                        Button("Finish sign-in") { store.finishClaudeLogin() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(store.claudeAuthorizationCode.isEmpty)
                            .opacity(store.claudeAuthorizationCode.isEmpty ? 0.5 : 1)
                            .accessibilityIdentifier("finish-claude-login")
                    }
                  }
                  if store.devinLoginProcess != nil || (store.remoteLoginIntegration == "devin" && store.loginSourceID != nil) {
                    HStack(spacing: 12) {
                        SecureField("Code from the Devin sign-in page", text: $store.devinAuthorizationCode)
                            .textFieldStyle(.roundedBorder).disabled(store.devinCodeSubmitted)
                            .accessibilityIdentifier("devin-authorization-code")
                        Button("Finish sign-in") { store.finishDevinLogin() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(store.devinAuthorizationCode.isEmpty || store.devinCodeSubmitted)
                            .accessibilityIdentifier("finish-devin-login")
                    }
                  }
                }.padding(16).background(Palette.inset).clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("account-sign-in")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(IntegrationID.allCases) { integration in
                    let configs = store.configuration?.sources.filter { $0.integration == integration } ?? []
                    if !configs.isEmpty {
                        SourceCard {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack(spacing: 12) {
                                    SourceIcon(integration: integration, size: 24)
                                    Text(integration.name).font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                    Text("\(configs.count) source\(configs.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                                    Button { store.showNewConnection(integration) } label: { Image(systemName: "plus") }
                                        .buttonStyle(.plain).foregroundStyle(Palette.blue).help("Add \(integration.name) connection")
                                        .accessibilityLabel("Add \(integration.name) connection")
                                }
                                if integration == .codex {
                                    Picker("Sign in using", selection: $store.loginMethod) {
                                        ForEach(CodexLoginMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                                    }.pickerStyle(.segmented).disabled(store.loginSourceID != nil)
                                    Text(store.loginMethod == .browser ? "Sign in opens UT Browser inside Argus." : "Sign in shows a link and code. Enable device-code login in ChatGPT security settings first.")
                                        .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                                }
                                ForEach(configs) { config in
                                    connectionRow(config)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if store.remoteAccountRequest == nil { DisclosureGroup("Advanced configuration") {
              HStack(spacing: 12) {
                Image(systemName: "lock.shield").foregroundStyle(Palette.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect and edit accounts above. Configuration files are optional; new keys live in Keychain.")
                    Text(IntegrationConfiguration.file.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Spacer()
                Button("Show config") { NSWorkspace.shared.activateFileViewerSelecting([IntegrationConfiguration.file]) }.buttonStyle(SecondaryButtonStyle())
                Button("Reload config") { Task { await store.reloadConnections() } }.buttonStyle(SecondaryButtonStyle()).disabled(store.refreshing)
              }.padding(.vertical, 10)
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections-page")
        .confirmationDialog("Remove this connection?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove connection", role: .destructive) {
                if let source = removing { Task { _ = await store.remoteAccountAction(["action": "remove", "sourceID": source.id]) } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
        .task {
            while store.remoteAccountRequest != nil && !Task.isCancelled {
                _ = await store.remoteAccountAction(["action": "state"])
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func connectionRow(_ configuration: SourceConfiguration) -> some View {
        let source = store.sources.first { $0.id == configuration.id }
        let failure = store.failures.first { $0.descriptor?.sourceID == configuration.id }
        let needsWork = failure != nil || source?.unavailable != nil || source?.hasLimitedAccess == true
        return VStack(alignment: .leading, spacing: 9) {
            Hairline()
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(configuration.label).font(.system(size: 12, weight: .semibold))
                    if let identity = source?.accountIdentity ?? configuration.accountIdentity {
                        Text(identity).font(.system(size: 10)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                SoftBadge(text: !configuration.enabled ? "Disabled" : (source?.connectionStatusTitle ?? failure?.errorTitle ?? "Waiting"),
                          symbol: needsWork ? "exclamationmark.circle" : "checkmark.circle", warning: needsWork)
                if configuration.integration.supportsAccountSignIn {
                    Button(configuration.hasSavedAccount ? "Change account" : "Sign in") { store.connectAccount(configuration.id) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(store.loginSourceID != nil || store.refreshing || !configuration.enabled)
                        .accessibilityIdentifier("connect-\(configuration.id)")
                }
                Button("Edit") { store.editConnection(configuration) }
                    .buttonStyle(SecondaryButtonStyle()).disabled(store.savingConnection || store.loginSourceID != nil)
                    .accessibilityIdentifier("edit-\(configuration.id)")
                if store.remoteAccountRequest != nil {
                    Button { removing = configuration } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).disabled(store.savingConnection || store.loginSourceID != nil)
                        .accessibilityLabel("Remove \(configuration.label)")
                }
                Button { Task { await store.refresh(sourceID: configuration.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                    .disabled(store.refreshing || store.savingConnection || !configuration.enabled || store.loginSourceID != nil)
                    .accessibilityLabel("Check \(configuration.label) connection")
            }
            if let message = failure?.error ?? source?.unavailable?.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let source, source.capabilities != nil { SourceAccessView(source: source) }
            if configuration.credentialReference != nil {
                HStack {
                    Label("Saved in macOS Keychain", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                    Spacer()
                    Button("Authorize saved key") { Task { await store.authorizeSavedCredential(configuration.id) } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(store.refreshing || store.authorizingCredentialID != nil || store.savingConnection)
                        .accessibilityIdentifier("authorize-key-\(configuration.id)")
                }
            } else if let file = configuration.credentialFile {
                Text("Using existing credential file").font(.system(size: 10)).foregroundStyle(Palette.tertiary).help(file)
            } else if let profile = configuration.codexHome {
                Text("Separate Codex login profile").font(.system(size: 10)).foregroundStyle(Palette.tertiary).help(profile)
            } else if let profile = configuration.loginProfile {
                Text("Private \(configuration.integration.name) login profile").font(.system(size: 10)).foregroundStyle(Palette.tertiary).help(profile)
            } else if let host = configuration.host {
                Text("UT host · \(host)").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            if let budget = configuration.budgetUSD {
                Text("Local monthly budget · \(UsageFormat.money(budget))").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
        }
    }
}
