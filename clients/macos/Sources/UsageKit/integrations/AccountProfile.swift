import Foundation

/// Account selection is explicit. A missing profile is a setup error, never an
/// invitation to read the ambient terminal login. Provider adapters only map
/// these owned roots onto their own CLI's environment/configuration format.
@available(macOS 14.0, *)
struct AccountProfile: Sendable {
    let root: URL

    init(path: String) throws {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"), !path.split(separator: "/").contains("..") else {
            throw IntegrationError.configuration("This account needs a valid private login profile. Sign in again in Connections.")
        }
        root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.path != "/" else { throw IntegrationError.configuration("The filesystem root cannot be an account profile.") }
    }

    static func create(in directory: URL) throws -> Self {
        let profile = try Self(path: directory.appendingPathComponent("login-\(UUID().uuidString.lowercased())", isDirectory: true).path)
        try FileManager.default.createDirectory(at: profile.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["data", "config", "cache"] {
            try FileManager.default.createDirectory(at: profile.root.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        return profile
    }

    var environment: [String: String] {
        ["HOME": root.path, "XDG_DATA_HOME": root.appendingPathComponent("data").path,
         "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
         "XDG_CACHE_HOME": root.appendingPathComponent("cache").path]
    }
}

@available(macOS 14.0, *)
struct VerifiedProfileLogin: Sendable {
    var profile: String
    var identity: String
}

@available(macOS 14.0, *)
enum AccountProfileCommit {
    /// Re-read after sign-in. Preserve concurrent metadata changes, reject a
    /// replaced/disabled connection, and keep the old profile on any failure.
    static func save(_ login: VerifiedProfileLogin, sourceID: String, integration: IntegrationID,
                     originalProfile: String?, repository: ConnectionRepository) throws {
        var latest = try repository.load()
        guard let index = latest.sources.firstIndex(where: { $0.id == sourceID && $0.integration == integration }),
              latest.sources[index].enabled,
              latest.sources[index].accountProfile == originalProfile else {
            throw IntegrationError.configuration("This connection changed during sign-in. Reopen Connections and try again.")
        }
        let identity = login.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { throw IntegrationError.authentication("Sign-in did not report an account identity.") }
        let profile = try AccountProfile(path: login.profile)
        for source in latest.sources where source.id != sourceID {
            if let other = source.accountProfile,
               URL(fileURLWithPath: other).resolvingSymlinksInPath().path == profile.root.resolvingSymlinksInPath().path {
                throw IntegrationError.configuration("Each connection must have its own login profile.")
            }
            if source.integration == integration, source.accountIdentity?.caseInsensitiveCompare(identity) == .orderedSame {
                throw IntegrationError.authentication("That account is already connected. Choose a different account on the sign-in page.")
            }
        }
        latest.sources[index].accountProfile = login.profile
        latest.sources[index].accountIdentity = identity
        try repository.saveConfiguration(latest, repository.url)
    }
}

@available(macOS 14.0, *)
extension SourceConfiguration {
    /// The old Codex configuration remains compatible with existing profiles.
    var accountProfile: String? {
        get { integration == .codex ? codexHome : loginProfile }
        set { if integration == .codex { codexHome = newValue } else { loginProfile = newValue } }
    }
    var hasSavedAccount: Bool { credentialReference != nil || accountProfile != nil }

    func validateAccountIdentity(_ actual: String?) throws {
        guard let expected = accountIdentity else { return }
        guard let actual, actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw IntegrationError.authentication("This profile no longer matches the connected account. Use Change account to reconnect it explicitly.")
        }
    }
}

@available(macOS 14.0, *)
extension IntegrationID {
    var supportsAccountSignIn: Bool { [.codex, .claude, .devin].contains(self) }
    var signInTitle: String { self == .codex ? "Sign in with ChatGPT" : "Sign in with \(self == .claude ? "Claude" : name)" }
}
