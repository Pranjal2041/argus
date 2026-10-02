import Foundation

/// Contains references to credentials, never credential values. Each account is independent.
@available(macOS 14.0, *)
struct SourceConfiguration: Identifiable, Codable, Sendable {
    var id: String
    var integration: IntegrationID
    var label: String
    var enabled = true
    var credentialFile: String?
    var credentialReference: String?
    var credentialVariables: [String: String] = [:]
    var codexHome: String?
    var loginProfile: String?
    var accountIdentity: String?
    var environment: String?
    var host: String?
    var mountPaths: [String]?
    var budgetUSD: Double?

    var descriptor: IntegrationDescriptor {
        IntegrationDescriptor(sourceID: id, integration: integration, label: label)
    }
}

@available(macOS 14.0, *)
extension SourceConfiguration {
    private enum CodingKeys: String, CodingKey {
        case id, integration, label, enabled, credentialFile, credentialReference, credentialVariables, codexHome, loginProfile, accountIdentity, environment, host, mountPaths, budgetUSD
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        integration = try values.decode(IntegrationID.self, forKey: .integration)
        label = try values.decode(String.self, forKey: .label)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        credentialFile = try values.decodeIfPresent(String.self, forKey: .credentialFile)
        credentialReference = try values.decodeIfPresent(String.self, forKey: .credentialReference)
        credentialVariables = try values.decodeIfPresent([String: String].self, forKey: .credentialVariables) ?? [:]
        codexHome = try values.decodeIfPresent(String.self, forKey: .codexHome)
        loginProfile = try values.decodeIfPresent(String.self, forKey: .loginProfile)
        accountIdentity = try values.decodeIfPresent(String.self, forKey: .accountIdentity)
        environment = try values.decodeIfPresent(String.self, forKey: .environment)
        host = try values.decodeIfPresent(String.self, forKey: .host)
        mountPaths = try values.decodeIfPresent([String].self, forKey: .mountPaths)
        budgetUSD = try values.decodeIfPresent(Double.self, forKey: .budgetUSD)
    }
}

@available(macOS 14.0, *)
struct IntegrationExecutables: Codable, Sendable {
    var codex = "/opt/homebrew/bin/codex"
    var uvx = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uvx").path
    var ut = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".universal-tmux/ut").path
    var devin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/devin").path

    init() {}
    private enum CodingKeys: String, CodingKey { case codex, uvx, ut, devin }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codex = try values.decodeIfPresent(String.self, forKey: .codex) ?? codex
        uvx = try values.decodeIfPresent(String.self, forKey: .uvx) ?? uvx
        ut = try values.decodeIfPresent(String.self, forKey: .ut) ?? ut
        devin = try values.decodeIfPresent(String.self, forKey: .devin) ?? devin
    }
}

@available(macOS 14.0, *)
struct IntegrationConfiguration: Codable, Sendable {
    var version = 1
    var executables = IntegrationExecutables()
    var sources: [SourceConfiguration]
    var refreshIntervalSeconds: Double = 120

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Argus/Usage", isDirectory: true)
    }
    static var file: URL {
        if let index = CommandLine.arguments.firstIndex(of: "--usage-config"), CommandLine.arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        return directory.appendingPathComponent("integrations.json")
    }

    static func load(from url: URL = file) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self(sources: [SourceConfiguration(id: "mac-local", integration: .macStorage, label: Host.current().localizedName ?? "This Mac")])
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1, Set(value.sources.map(\.id)).count == value.sources.count,
              value.sources.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty }),
              value.sources.allSatisfy({ $0.budgetUSD == nil || ($0.budgetUSD!.isFinite && $0.budgetUSD! > 0) }) else {
            throw IntegrationError.configuration("Invalid integration configuration: check version, unique IDs, labels, and positive budgets.")
        }
        return value
    }

    func save(to url: URL = Self.file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@available(macOS 14.0, *)
extension IntegrationConfiguration {
    private enum CodingKeys: String, CodingKey { case version, executables, sources, refreshIntervalSeconds }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        executables = try values.decodeIfPresent(IntegrationExecutables.self, forKey: .executables) ?? IntegrationExecutables()
        sources = try values.decode([SourceConfiguration].self, forKey: .sources)
        refreshIntervalSeconds = try values.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? 120
    }
}

@available(macOS 14.0, *)
struct IntegrationDescriptor: Sendable {
    var sourceID: String
    var integration: IntegrationID
    var label: String
}

@available(macOS 14.0, *)
enum IntegrationError: Error, LocalizedError, Sendable {
    case configuration(String)
    case authentication(String)
    case permission(String)
    case unavailable(String)
    case invalidResponse(String)
    case timeout
    case commandFailed

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .authentication(let message), .permission(let message),
             .unavailable(let message), .invalidResponse(let message): message
        case .timeout: "The service took too long to respond. The last reading is preserved."
        case .commandFailed: "The provider command failed. Check the connection and try again."
        }
    }
    var needsAuthentication: Bool {
        if case .authentication = self { true } else { false }
    }
    var title: String {
        switch self {
        case .authentication: "Connect account"
        case .permission: "Access required"
        case .configuration: "Setup required"
        default: "Unavailable"
        }
    }
}

@available(macOS 14.0, *)
enum CredentialReader {
    /// Parse dotenv as data. Never source a credential file or evaluate shell substitutions.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, (quote == "\"" || quote == "'"), value.last == quote, value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }

    static func values(for source: SourceConfiguration, required: [String], secrets: any CredentialStoring = KeychainCredentialStore()) throws -> [String: String] {
        if let reference = source.credentialReference {
            let values = try secrets.read(reference: reference)
            guard required.allSatisfy({ values[$0]?.isEmpty == false }) else {
                throw IntegrationError.authentication("The saved credentials are incomplete. Edit this connection to replace them.")
            }
            return values.filter { required.contains($0.key) }
        }
        guard let path = source.credentialFile else { throw IntegrationError.authentication("Configure a credential file for this source.") }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw IntegrationError.authentication("The configured credential file cannot be read.")
        }
        let parsed = parse(text)
        var selected: [String: String] = [:]
        for name in required {
            guard let value = parsed[source.credentialVariables[name] ?? name], !value.isEmpty else {
                throw IntegrationError.authentication("The credential file is missing \(name).")
            }
            selected[name] = value
        }
        return selected
    }
}
