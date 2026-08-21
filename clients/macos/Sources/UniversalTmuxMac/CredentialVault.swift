import AppKit
import CryptoKit
import Foundation
import Security

struct CredentialVaultEntry: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var group: String
    let createdAt: Date
    var updatedAt: Date

    var displayGroup: String { group.isEmpty ? "Ungrouped" : group }
}

struct CredentialVaultSecret: Codable, Equatable {
    var username: String
    var password: String

    func value(for field: String) -> String? {
        switch field.lowercased() {
        case "username", "email", "login": return username
        case "password", "secret": return password
        default: return nil
        }
    }
}

struct BrowserCredentialCaller: Codable, Equatable {
    var machineName: String
    var machineHost: String
    var sessionName: String
    var stableSessionID: String
    var sessionLineageID: String

    var displayName: String {
        let machine = machineName.isEmpty ? machineHost : machineName
        if sessionName.isEmpty { return machine.isEmpty ? "Unknown agent" : machine }
        return machine.isEmpty ? sessionName : "\(sessionName) on \(machine)"
    }

    var policyPrincipal: String {
        // Saved "always" rules deliberately follow the named panel on one machine.
        [machineHost.lowercased(), machineName.lowercased(), sessionName.lowercased()]
            .joined(separator: "|")
    }

    var grantPrincipal: String {
        // Live grants bind to the actual panel identity, not merely its name. A
        // later panel reusing that name cannot replay an old one-day token.
        let identity = !sessionLineageID.isEmpty ? sessionLineageID
            : (!stableSessionID.isEmpty ? stableSessionID : sessionName)
        return [machineHost.lowercased(), machineName.lowercased(),
                sessionName.lowercased(), identity.lowercased()].joined(separator: "|")
    }

    var isAttributed: Bool { !sessionName.isEmpty && (!machineName.isEmpty || !machineHost.isEmpty) }
}

enum CredentialGrantDuration: String, Codable, CaseIterable, Identifiable {
    case once
    case panel
    case oneDay
    case always

    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: return "Once"
        case .panel: return "Until this panel ends"
        case .oneDay: return "For 1 day"
        case .always: return "Always"
        }
    }
}

enum CredentialGrantScope: String, Codable, CaseIterable, Identifiable {
    case credential
    case group
    case vault

    var id: String { rawValue }
}

struct CredentialGrantResponse {
    let token: String
    let duration: CredentialGrantDuration
    let scope: CredentialGrantScope
}

final class CredentialApprovalRequest: Identifiable, ObservableObject {
    let id = UUID()
    let entry: CredentialVaultEntry
    let caller: BrowserCredentialCaller
    let domain: String
    @Published var duration: CredentialGrantDuration = .once
    @Published var scope: CredentialGrantScope = .credential
    @Published var restrictToDomain = false

    fileprivate let continuation: CheckedContinuation<CredentialGrantResponse, Error>

    init(entry: CredentialVaultEntry, caller: BrowserCredentialCaller, domain: String,
         continuation: CheckedContinuation<CredentialGrantResponse, Error>) {
        self.entry = entry
        self.caller = caller
        self.domain = domain
        self.continuation = continuation
    }
}

private struct CredentialGrantPolicy: Codable, Hashable {
    var principal: String
    var scope: CredentialGrantScope
    var scopeValue: String
    var restrictedDomain: String?
    var createdAt: Date
}

private struct ActiveCredentialGrant {
    var principal: String
    var scope: CredentialGrantScope
    var scopeValue: String
    var restrictedDomain: String?
    var expiresAt: Date?
    var remainingUses: Int?
    var duration: CredentialGrantDuration
    var unattendedOnly: Bool
}

struct CredentialVaultAuditEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let action: String
    let credentialName: String
    let caller: String
}

protocol CredentialSecretStore {
    func read(id: UUID) throws -> CredentialVaultSecret
    func write(id: UUID, secret: CredentialVaultSecret, availableAfterFirstUnlock: Bool) throws
    func delete(id: UUID) throws
    func setAvailableAfterFirstUnlock(_ enabled: Bool, ids: [UUID]) throws
}

final class KeychainCredentialSecretStore: CredentialSecretStore {
    private let service = "com.universal-tmux.Argus.credential-vault"

    func read(id: UUID) throws -> CredentialVaultSecret {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { throw CredentialVaultError.secretMissing }
            throw CredentialVaultError.keychain(status)
        }
        do { return try JSONDecoder().decode(CredentialVaultSecret.self, from: data) }
        catch { throw CredentialVaultError.secretUnreadable }
    }

    func write(id: UUID, secret: CredentialVaultSecret, availableAfterFirstUnlock: Bool) throws {
        let data = try JSONEncoder().encode(secret)
        let accessibility = availableAfterFirstUnlock
            ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
            kSecAttrLabel as String: "Argus credential"
        ]
        let updateStatus = SecItemUpdate(baseQuery(id: id) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialVaultError.keychain(updateStatus) }
        attributes.merge(baseQuery(id: id)) { current, _ in current }
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialVaultError.keychain(addStatus) }
    }

    func delete(id: UUID) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status)
        }
    }

    func setAvailableAfterFirstUnlock(_ enabled: Bool, ids: [UUID]) throws {
        let accessibility = enabled
            ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        for id in ids {
            let status = SecItemUpdate(
                baseQuery(id: id) as CFDictionary,
                [kSecAttrAccessible as String: accessibility] as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialVaultError.keychain(status)
            }
        }
    }

    private func baseQuery(id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false
        ]
    }
}

enum CredentialVaultError: LocalizedError {
    case invalid(String)
    case notFound(String)
    case denied
    case grantInvalid
    case secretMissing
    case secretUnreadable
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .notFound(let message): return message
        case .denied: return "Credential access was denied."
        case .grantInvalid: return "This credential grant is invalid, expired, or outside its approved scope."
        case .secretMissing: return "The credential secret is missing from this Mac."
        case .secretUnreadable: return "The credential secret could not be decoded."
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}

@MainActor
final class CredentialVaultStore: ObservableObject {
    @Published private(set) var entries: [CredentialVaultEntry] = []
    @Published private(set) var pendingApproval: CredentialApprovalRequest?
    @Published private(set) var auditEvents: [CredentialVaultAuditEvent] = []
    @Published private(set) var allowInUnattendedMode: Bool
    @Published var errorMessage: String?
    var unattendedModeActive = false {
        didSet {
            if !unattendedModeActive {
                activeGrants = activeGrants.filter { !$0.value.unattendedOnly }
            }
        }
    }

    private let secretStore: CredentialSecretStore
    private let defaults: UserDefaults
    private var policies: [CredentialGrantPolicy] = []
    private var activeGrants: [String: ActiveCredentialGrant] = [:]
    private var approvalQueue: [CredentialApprovalRequest] = []

    private static let entriesKey = "ut.credentialVault.entries.v1"
    private static let policiesKey = "ut.credentialVault.policies.v1"
    private static let auditKey = "ut.credentialVault.audit.v1"
    private static let unattendedKey = "ut.credentialVault.allowUnattended"

    init(secretStore: CredentialSecretStore = KeychainCredentialSecretStore(),
         defaults: UserDefaults = .standard) {
        self.secretStore = secretStore
        self.defaults = defaults
        self.allowInUnattendedMode = defaults.bool(forKey: Self.unattendedKey)
        entries = Self.decode([CredentialVaultEntry].self, defaults.data(forKey: Self.entriesKey)) ?? []
        policies = Self.decode([CredentialGrantPolicy].self, defaults.data(forKey: Self.policiesKey)) ?? []
        auditEvents = Self.decode([CredentialVaultAuditEvent].self, defaults.data(forKey: Self.auditKey)) ?? []
        sortEntries()
    }

    var groups: [String] {
        Array(Set(entries.map(\.group).filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func entry(named name: String) -> CredentialVaultEntry? {
        entries.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }

    func save(id: UUID? = nil, name: String, group: String,
              username: String, password: String) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw CredentialVaultError.invalid("Credential name is required.") }
        guard !password.isEmpty else { throw CredentialVaultError.invalid("Password is required.") }
        if entries.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) {
            throw CredentialVaultError.invalid("A credential named \"\(cleanName)\" already exists.")
        }
        let now = Date()
        let entryID = id ?? UUID()
        let createdAt = entries.first(where: { $0.id == entryID })?.createdAt ?? now
        try secretStore.write(
            id: entryID,
            secret: CredentialVaultSecret(username: username, password: password),
            availableAfterFirstUnlock: allowInUnattendedMode
        )
        let entry = CredentialVaultEntry(id: entryID, name: cleanName, group: cleanGroup,
                                         createdAt: createdAt, updatedAt: now)
        if let index = entries.firstIndex(where: { $0.id == entryID }) { entries[index] = entry }
        else { entries.append(entry) }
        sortEntries()
        persistEntries()
        audit("saved", entry: entry, caller: "You")
    }

    func secret(for entry: CredentialVaultEntry) throws -> CredentialVaultSecret {
        try secretStore.read(id: entry.id)
    }

    func delete(_ entry: CredentialVaultEntry) throws {
        try secretStore.delete(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        policies.removeAll { policy in
            policy.scope == .credential && policy.scopeValue == entry.id.uuidString.lowercased()
        }
        persistEntries()
        persistPolicies()
        audit("deleted", entry: entry, caller: "You")
    }

    func setAllowInUnattendedMode(_ enabled: Bool) {
        do {
            try secretStore.setAvailableAfterFirstUnlock(enabled, ids: entries.map(\.id))
            allowInUnattendedMode = enabled
            defaults.set(enabled, forKey: Self.unattendedKey)
            if !enabled {
                activeGrants = activeGrants.filter { !$0.value.unattendedOnly }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestGrant(credentialName: String, caller: BrowserCredentialCaller,
                      domain: String) async throws -> CredentialGrantResponse {
        guard caller.isAttributed else {
            throw CredentialVaultError.invalid("Credential access must be requested from a verified ut panel.")
        }
        guard let entry = entry(named: credentialName) else {
            throw CredentialVaultError.notFound("No Argus Vault credential is named \"\(credentialName)\".")
        }
        pruneGrants()
        if unattendedModeActive && allowInUnattendedMode {
            let response = issueGrant(entry: entry, caller: caller, scope: .vault,
                                      duration: .panel, restrictedDomain: nil, unattendedOnly: true)
            audit("granted unattended access", entry: entry, caller: caller.displayName)
            return response
        }
        if let policy = policies.first(where: { policyAllows($0, entry: entry, caller: caller, domain: domain) }) {
            let response = issueGrant(entry: entry, caller: caller, scope: policy.scope,
                                      duration: .panel, restrictedDomain: policy.restrictedDomain,
                                      unattendedOnly: false, scopeValue: policy.scopeValue)
            audit("granted saved access", entry: entry, caller: caller.displayName)
            return response
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = CredentialApprovalRequest(entry: entry, caller: caller, domain: domain,
                                                    continuation: continuation)
            if pendingApproval == nil {
                pendingApproval = request
                NSApp?.requestUserAttention(.criticalRequest)
            } else {
                approvalQueue.append(request)
            }
        }
    }

    func approvePending() {
        guard let request = pendingApproval else { return }
        var scope = request.scope
        if scope == .group && request.entry.group.isEmpty { scope = .credential }
        let domain = request.restrictToDomain && !request.domain.isEmpty ? request.domain.lowercased() : nil
        let scopeValue = value(for: scope, entry: request.entry)
        if request.duration == .always {
        let policy = CredentialGrantPolicy(principal: request.caller.policyPrincipal,
                                               scope: scope, scopeValue: scopeValue,
                                               restrictedDomain: domain, createdAt: Date())
            policies.removeAll {
                $0.principal == policy.principal && $0.scope == policy.scope &&
                    $0.scopeValue == policy.scopeValue && $0.restrictedDomain == policy.restrictedDomain
            }
            policies.append(policy)
            persistPolicies()
        }
        let response = issueGrant(entry: request.entry, caller: request.caller, scope: scope,
                                  duration: request.duration, restrictedDomain: domain,
                                  unattendedOnly: false, scopeValue: scopeValue)
        audit("approved \(request.duration.title.lowercased())", entry: request.entry,
              caller: request.caller.displayName)
        finishCurrent { request.continuation.resume(returning: response) }
    }

    func denyPending() {
        guard let request = pendingApproval else { return }
        audit("denied", entry: request.entry, caller: request.caller.displayName)
        finishCurrent { request.continuation.resume(throwing: CredentialVaultError.denied) }
    }

    func resolve(grant token: String, credentialName: String,
                 caller: BrowserCredentialCaller, domain: String) throws -> (CredentialVaultEntry, CredentialVaultSecret) {
        pruneGrants()
        let key = Self.digest(token)
        guard let grant = activeGrants[key], grant.principal == caller.grantPrincipal,
              (!grant.unattendedOnly || (unattendedModeActive && allowInUnattendedMode)),
              let entry = entry(named: credentialName),
              scopeAllows(grant.scope, value: grant.scopeValue, entry: entry),
              grant.restrictedDomain == nil || grant.restrictedDomain == domain.lowercased() else {
            throw CredentialVaultError.grantInvalid
        }
        return (entry, try secretStore.read(id: entry.id))
    }

    func markGrantUsed(_ token: String, entry: CredentialVaultEntry, caller: BrowserCredentialCaller) {
        let key = Self.digest(token)
        guard var grant = activeGrants[key] else { return }
        if let remaining = grant.remainingUses {
            if remaining <= 1 { activeGrants.removeValue(forKey: key) }
            else { grant.remainingUses = remaining - 1; activeGrants[key] = grant }
        }
        audit("filled browser fields", entry: entry, caller: caller.displayName)
    }

    func revokeSavedPolicies() {
        policies = []
        persistPolicies()
    }

    private func finishCurrent(_ completion: () -> Void) {
        pendingApproval = nil
        completion()
        if !approvalQueue.isEmpty {
            pendingApproval = approvalQueue.removeFirst()
            NSApp?.requestUserAttention(.criticalRequest)
        }
    }

    private func issueGrant(entry: CredentialVaultEntry, caller: BrowserCredentialCaller,
                            scope: CredentialGrantScope, duration: CredentialGrantDuration,
                            restrictedDomain: String?, unattendedOnly: Bool,
                            scopeValue explicitScopeValue: String? = nil) -> CredentialGrantResponse {
        let token = Self.randomToken()
        let expiry: Date?
        switch duration {
        case .oneDay: expiry = Date().addingTimeInterval(24 * 60 * 60)
        default: expiry = nil
        }
        activeGrants[Self.digest(token)] = ActiveCredentialGrant(
            principal: caller.grantPrincipal,
            scope: scope,
            scopeValue: explicitScopeValue ?? value(for: scope, entry: entry),
            restrictedDomain: restrictedDomain,
            expiresAt: expiry,
            remainingUses: duration == .once ? 1 : nil,
            duration: duration,
            unattendedOnly: unattendedOnly
        )
        return CredentialGrantResponse(token: token, duration: duration, scope: scope)
    }

    private func policyAllows(_ policy: CredentialGrantPolicy, entry: CredentialVaultEntry,
                              caller: BrowserCredentialCaller, domain: String) -> Bool {
        policy.principal == caller.policyPrincipal &&
            scopeAllows(policy.scope, value: policy.scopeValue, entry: entry) &&
            (policy.restrictedDomain == nil || policy.restrictedDomain == domain.lowercased())
    }

    private func scopeAllows(_ scope: CredentialGrantScope, value: String,
                             entry: CredentialVaultEntry) -> Bool {
        switch scope {
        case .credential: return value == entry.id.uuidString.lowercased()
        case .group: return !entry.group.isEmpty && value.caseInsensitiveCompare(entry.group) == .orderedSame
        case .vault: return true
        }
    }

    private func value(for scope: CredentialGrantScope, entry: CredentialVaultEntry) -> String {
        switch scope {
        case .credential: return entry.id.uuidString.lowercased()
        case .group: return entry.group
        case .vault: return "*"
        }
    }

    private func pruneGrants() {
        let now = Date()
        activeGrants = activeGrants.filter { _, grant in
            grant.expiresAt.map { $0 > now } ?? true
        }
    }

    private func sortEntries() {
        entries.sort { left, right in
            if left.group.caseInsensitiveCompare(right.group) != .orderedSame {
                return left.group.localizedCaseInsensitiveCompare(right.group) == .orderedAscending
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private func persistEntries() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.entriesKey)
    }

    private func persistPolicies() {
        defaults.set(try? JSONEncoder().encode(policies), forKey: Self.policiesKey)
    }

    private func audit(_ action: String, entry: CredentialVaultEntry, caller: String) {
        auditEvents.insert(CredentialVaultAuditEvent(id: UUID(), timestamp: Date(), action: action,
                                                     credentialName: entry.name, caller: caller), at: 0)
        if auditEvents.count > 100 { auditEvents.removeLast(auditEvents.count - 100) }
        defaults.set(try? JSONEncoder().encode(auditEvents), forKey: Self.auditKey)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "") +
                UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
