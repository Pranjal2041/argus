import Foundation
import Security
import LocalAuthentication

protocol CredentialStoring: Sendable {
    func read(reference: String) throws -> [String: String]
    func save(_ values: [String: String], reference: String) throws
    func delete(reference: String) throws
    func update(_ values: [String: String], reference: String) throws
}

extension CredentialStoring {
    func update(_ values: [String: String], reference: String) throws {
        throw IntegrationError.configuration("This credential store does not support token renewal.")
    }
}

/// Only this app's named generic-password items are accessed. Secrets never enter configuration JSON.
struct KeychainCredentialStore: CredentialStoring {
    static let service = "com.pranjal.usage.credentials"
    private static let legacyReadLock = NSLock()

    private func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: reference]
    }

    func read(reference: String) throws -> [String: String] {
        try read(reference: reference, allowInteraction: false)
    }

    /// Explicit user action only; background refresh always calls the non-interactive overload.
    func authorize(reference: String) throws {
        _ = try read(reference: reference, allowInteraction: true)
    }

    private func read(reference: String, allowInteraction: Bool) throws -> [String: String] {
        var request = query(reference)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background refresh must never unexpectedly present a Keychain authorization dialog.
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        // LAContext alone does not suppress legacy login-keychain ACL prompts on macOS.
        // Serialize the process-wide legacy setting and restore it after this exact read.
        Self.legacyReadLock.lock()
        defer { Self.legacyReadLock.unlock() }
        var interactionAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&interactionAllowed)
        SecKeychainSetUserInteractionAllowed(allowInteraction)
        defer { SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) }
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw IntegrationError.authentication("macOS has not authorized this build to read the saved key. In Connections, choose Authorize saved key. Your provider key and its permissions are unchanged.")
        }
        return values
    }

    func save(_ values: [String: String], reference: String) throws {
        var request = query(reference)
        request[kSecValueData as String] = try JSONEncoder().encode(values)
        request[kSecAttrLabel as String] = "Usage integration credentials"
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IntegrationError.configuration("Could not save credentials to macOS Keychain (status \(status)). No credential values were written to the configuration file.")
        }
    }

    func delete(reference: String) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IntegrationError.configuration("Could not remove an unused Usage credential from Keychain.")
        }
    }

    func update(_ values: [String: String], reference: String) throws {
        var request = query(reference)
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        Self.legacyReadLock.lock()
        defer { Self.legacyReadLock.unlock() }
        var interactionAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&interactionAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) }
        let status = SecItemUpdate(request as CFDictionary,
            [kSecValueData as String: try JSONEncoder().encode(values)] as CFDictionary)
        guard status == errSecSuccess else {
            throw IntegrationError.authentication("Could not save the renewed Claude login. Reconnect this account in Connections.")
        }
    }
}
