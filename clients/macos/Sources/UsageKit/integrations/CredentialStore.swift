import Foundation
import Security
import LocalAuthentication

@available(macOS 14.0, *)
protocol CredentialStoring: Sendable {
    func read(reference: String) throws -> [String: String]
    func save(_ values: [String: String], reference: String) throws
    func delete(reference: String) throws
    func update(_ values: [String: String], reference: String) throws
}

@available(macOS 14.0, *)
extension CredentialStoring {
    func update(_ values: [String: String], reference: String) throws {
        throw IntegrationError.configuration("This credential store does not support token renewal.")
    }
}

/// Only this app's named generic-password items are accessed. Secrets never enter configuration JSON.
@available(macOS 14.0, *)
struct KeychainCredentialStore: CredentialStoring {
    static let service = "com.pranjal.usage.credentials"
    private static let legacyReadLock = NSLock()
    var worker: any UsageCredentialRunning = UsageCredentialProcess()
    var isWorker = false

    private func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: reference]
    }

    func read(reference: String) throws -> [String: String] {
        if !isWorker { return try worker.perform(.init(operation: .read, reference: reference)).values ?? [:] }
        return try read(reference: reference, allowInteraction: false)
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
        // LAContext alone does not suppress legacy ACL prompts. Only the isolated
        // worker changes the process-wide switch; explicit authorization in the
        // host must leave the browser/vault's Keychain behavior untouched.
        var interactionAllowed: DarwinBoolean = true
        if !allowInteraction {
            Self.legacyReadLock.lock()
            SecKeychainGetUserInteractionAllowed(&interactionAllowed)
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer {
            if !allowInteraction {
                SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue)
                Self.legacyReadLock.unlock()
            }
        }
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.failure(for: status) }
        guard let data = result as? Data,
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw IntegrationError.invalidResponse("The saved credential could not be decoded.")
        }
        return values
    }

    /// Keychain availability and provider authentication are separate facts.
    /// Only a genuinely missing credential is a missing account credential;
    /// lock, IPC, decoding, and worker failures must not demand a fresh login.
    static func failure(for status: OSStatus) -> IntegrationError {
        switch status {
        case errSecItemNotFound:
            return .authentication("This connection has no saved credential.")
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .permission("macOS could not unlock this connection's saved credential. Argus will retry automatically.")
        case errSecDecode:
            return .invalidResponse("The saved credential could not be decoded.")
        default:
            return .unavailable("The credential service is temporarily unavailable (status \(status)). Argus will retry automatically.")
        }
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
        if !isWorker {
            _ = try worker.perform(.init(operation: .update, reference: reference, values: values))
            return
        }
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
            throw Self.failure(for: status)
        }
    }
}
