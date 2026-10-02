import Foundation

@available(macOS 14.0, *)
struct CredentialField: Identifiable, Sendable {
    var id: String
    var title: String
}

@available(macOS 14.0, *)
extension IntegrationID {
    var credentialFields: [CredentialField] {
        switch self {
        case .daytona: [CredentialField(id: "DAYTONA_API_KEY", title: "API key")]
        case .modal: [CredentialField(id: "MODAL_TOKEN_ID", title: "Token ID"), CredentialField(id: "MODAL_TOKEN_SECRET", title: "Token secret")]
        case .openaiAPI: [CredentialField(id: "OPENAI_ADMIN_KEY", title: "Organization admin key")]
        default: []
        }
    }
    var connectionHelp: String {
        switch self {
        case .daytona: "Use a Daytona API key with read:limits and read:billing for limits and spending. Basic keys may only list sandboxes. Billing uses a separate service; Usage checks its access independently."
        case .modal: "Use the token ID and secret for one Modal workspace. Containers use the environment below; billing covers the workspace."
        case .openaiAPI: "Organization costs require an admin key with api.usage.read. A normal project or person key cannot read billing."
        case .codex: "Sign in with ChatGPT in UT Browser, or use a device code. Argus keeps a separate profile and never signs out your existing CLI accounts."
        case .claude: "Connect each Claude subscription separately. Open the sign-in link, choose this account, and paste the returned code here. Usage saves its own login in Keychain, independent of your Claude Code terminal accounts."
        case .devin: "Sign in with Devin in UT Browser, then paste the returned code here. Each connection has its own private CLI login. Changing this account never switches your terminal's Devin account or another connection."
        case .macStorage: "Read capacity from a local volume. No folders are scanned and no files are changed."
        case .windowsStorage: "Read Windows drive capacity through an existing UT connection. Enter the machine's UT host name."
        }
    }
}

/// Editable non-secret metadata plus transient input. This type is deliberately not Codable.
@available(macOS 14.0, *)
struct ConnectionDraft: Identifiable, Sendable {
    let id = UUID()
    var sourceID: String?
    var integration: IntegrationID = .codex
    var label = ""
    var enabled = true
    var credentials: [String: String] = [:]
    var hasSavedCredentials = false
    var hasSavedProfile = false
    var environment = "main"
    var host = ""
    var mountPath = "/System/Volumes/Data"
    var budget = ""
    var useExistingCodexProfile = false
    var codexHome = ""
    var codexLoginMethod: CodexLoginMethod = .browser

    init(integration: IntegrationID = .codex) { self.integration = integration }
    init(source: SourceConfiguration) {
        sourceID = source.id; integration = source.integration; label = source.label; enabled = source.enabled
        hasSavedCredentials = source.credentialReference != nil || source.credentialFile != nil
        hasSavedProfile = source.accountProfile != nil
        environment = source.environment ?? "main"; host = source.host ?? ""
        mountPath = source.mountPaths?.joined(separator: "\n") ?? "/System/Volumes/Data"
        budget = source.budgetUSD.map { String($0) } ?? ""
        codexHome = source.codexHome ?? ""; useExistingCodexProfile = true
    }
    var startsCodexLogin: Bool { integration == .codex && !useExistingCodexProfile && enabled }
    var startsClaudeLogin: Bool { integration == .claude && enabled && !hasSavedCredentials }
    var startsDevinLogin: Bool { integration == .devin && enabled && !hasSavedProfile }
    var startsAccountLogin: Bool { startsCodexLogin || startsClaudeLogin || startsDevinLogin }
}

/// Persists a single connection without altering other accounts or their original dotenv files.
@available(macOS 14.0, *)
struct ConnectionRepository: Sendable {
    var url: URL = IntegrationConfiguration.file
    var secrets: any CredentialStoring = KeychainCredentialStore()
    var profilesDirectory: URL = IntegrationConfiguration.directory.appendingPathComponent("profiles", isDirectory: true)
    var saveConfiguration: @Sendable (IntegrationConfiguration, URL) throws -> Void = { try $0.save(to: $1) }

    func load() throws -> IntegrationConfiguration { try .load(from: url) }

    func save(_ draft: ConnectionDraft) throws -> SourceConfiguration {
        var config = try load()
        let existing = draft.sourceID.flatMap { id in config.sources.first { $0.id == id } }
        guard draft.sourceID == nil || existing?.integration == draft.integration else {
            throw IntegrationError.configuration("This connection changed or was removed. Reopen it before saving.")
        }
        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw IntegrationError.configuration("Give this connection a name, such as Personal or Work.") }
        let id = existing?.id ?? "\(draft.integration.rawValue)-\(UUID().uuidString.lowercased())"
        var source = existing ?? SourceConfiguration(id: id, integration: draft.integration, label: label)
        source.label = label; source.enabled = draft.enabled
        let budget = draft.budget.trimmingCharacters(in: .whitespacesAndNewlines)
        if budget.isEmpty { source.budgetUSD = nil }
        else {
            guard let amount = Double(budget), amount.isFinite, amount > 0 else {
                throw IntegrationError.configuration("The optional monthly budget must be a positive USD amount.")
            }
            source.budgetUSD = amount
        }
        switch draft.integration {
        case .modal:
            let environment = draft.environment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !environment.isEmpty else { throw IntegrationError.configuration("Enter a Modal environment, such as main.") }
            source.environment = environment
        case .codex:
            if draft.useExistingCodexProfile {
                let path = NSString(string: draft.codexHome.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
                    throw IntegrationError.configuration("Choose an existing Codex profile folder, or use browser sign-in.")
                }
                source.codexHome = path
            } else { source.codexHome = existing?.codexHome ?? profilesDirectory.appendingPathComponent(id, isDirectory: true).path }
        case .macStorage:
            let paths = draft.mountPath.components(separatedBy: .newlines).map { NSString(string: $0.trimmingCharacters(in: .whitespaces)).expandingTildeInPath }.filter { !$0.isEmpty }
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }) else {
                throw IntegrationError.configuration("Enter an existing absolute volume path, such as /System/Volumes/Data.")
            }
            source.mountPaths = paths
        case .windowsStorage:
            let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
                throw IntegrationError.configuration("Enter a UT machine name using letters, digits, periods, underscores, or hyphens.")
            }
            source.host = host
        default: break
        }

        let fields = draft.integration.credentialFields
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, (draft.credentials[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) })
        let replacing = values.values.contains { !$0.isEmpty }
        guard fields.isEmpty || (replacing ? values.values.allSatisfy({ !$0.isEmpty }) : (source.credentialReference != nil || source.credentialFile != nil)) else {
            throw IntegrationError.configuration(draft.integration == .modal ? "Enter both the Modal token ID and token secret." : "Enter the key for this account.")
        }

        var newReference: String?
        if replacing {
            let reference = "argus-usage-credential-\(UUID().uuidString.lowercased())"
            try secrets.save(values, reference: reference)
            newReference = reference; source.credentialReference = reference
            source.credentialFile = nil; source.credentialVariables = [:]
        }
        if let index = config.sources.firstIndex(where: { $0.id == source.id }) { config.sources[index] = source }
        else { config.sources.append(source) }
        do { try saveConfiguration(config, url) }
        catch {
            if let newReference { try? secrets.delete(reference: newReference) }
            throw IntegrationError.configuration("Couldn't save this connection. Existing account configuration is unchanged.")
        }
        if let oldReference = existing?.credentialReference, oldReference.hasPrefix("argus-usage-"), oldReference != source.credentialReference,
           !config.sources.contains(where: { $0.credentialReference == oldReference }) {
            try? secrets.delete(reference: oldReference)
        }
        return source
    }
}
