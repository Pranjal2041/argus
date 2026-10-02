import Foundation
import CryptoKit
import Security

/// Independent PKCE grants: no CLI files, Keychain entries, or shell aliases are imported.
@available(macOS 14.0, *)
struct ClaudeLoginFlow: Sendable {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirect = "https://platform.claude.com/oauth/code/callback"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    let verifier: String
    let state: String
    let createdAt: Date

    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw IntegrationError.unavailable("Could not start a secure sign-in. Try again.")
            }
            return Self.base64URL(Data(bytes))
        }
        verifier = try random(); state = try random(); createdAt = .now
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var url: URL {
        var url = URLComponents(string: "https://claude.com/cai/oauth/authorize")!
        url.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            // Usage only needs profile/usage access, not inference or sessions.
            URLQueryItem(name: "scope", value: "user:profile"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return url.url!
    }
    func exchange(code input: String, client: any HTTPClient) async throws -> [String: String] {
        guard Date.now.timeIntervalSince(createdAt) < 600 else {
            throw IntegrationError.authentication("This sign-in expired. Cancel and start again.")
        }
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1] == Substring(state) else {
            throw IntegrationError.authentication("Paste the complete code from this sign-in, including the # suffix.")
        }
        return try await ClaudeOAuth.tokens(body: ["grant_type": "authorization_code", "code": String(parts[0]),
            "client_id": Self.clientID, "redirect_uri": Self.redirect, "state": state, "code_verifier": verifier], client: client)
    }
}

@available(macOS 14.0, *)
enum ClaudeOAuth {
    static func tokens(body: [String: String], previous: [String: String] = [:], client: any HTTPClient) async throws -> [String: String] {
        var request = URLRequest(url: ClaudeLoginFlow.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let response = try await client.send(request)
        guard response.status == 200 else {
            if [400, 401, 403].contains(response.status) { throw IntegrationError.authentication("Claude sign-in expired or was rejected. Reconnect this account.") }
            throw IntegrationError.unavailable("Claude sign-in is temporarily unavailable. Try again shortly.")
        }
        let value = try JSONValue.decode(response.data)
        guard let access = value["access_token"].string, !access.isEmpty,
              let duration = value["expires_in"].double, duration.isFinite, duration > 0 else {
            throw IntegrationError.invalidResponse("Claude did not return a usable login.")
        }
        let scope = value["scope"].string ?? previous["scope"] ?? ""
        guard scope.split(separator: " ").contains("user:profile") else {
            throw IntegrationError.authentication("This Claude login does not grant usage access. Sign in again.")
        }
        var result = previous
        result["accessToken"] = access
        result["refreshToken"] = value["refresh_token"].string ?? previous["refreshToken"]
        result["expiresAt"] = String(Date.now.timeIntervalSince1970 + duration)
        result["scope"] = scope
        return result
    }

    /// Re-read config after browser sign-in; preserve unrelated edits and the old grant on failure.
    static func save(_ values: [String: String], sourceID: String, originalReference: String?,
                     repository: ConnectionRepository) throws {
        var config = try repository.load()
        guard let index = config.sources.firstIndex(where: { $0.id == sourceID && $0.integration == .claude }),
              config.sources[index].credentialReference == originalReference else {
            throw IntegrationError.configuration("This connection changed during sign-in. Reopen Connections and try again.")
        }
        let identity = values["accountID"] ?? values["email"]
        for other in config.sources where other.integration == .claude && other.id != sourceID {
            if let reference = other.credentialReference {
                let saved = try repository.secrets.read(reference: reference)
                if let identity, identity == (saved["accountID"] ?? saved["email"]) {
                    throw IntegrationError.authentication("That Claude account is already connected. Choose another account on the sign-in page.")
                }
            }
        }
        let reference = "argus-usage-credential-\(UUID().uuidString.lowercased())"
        try repository.secrets.save(values, reference: reference)
        config.sources[index].credentialReference = reference
        config.sources[index].credentialFile = nil
        do { try repository.saveConfiguration(config, repository.url) }
        catch { try? repository.secrets.delete(reference: reference); throw error }
        if let originalReference, originalReference.hasPrefix("argus-usage-"), !config.sources.contains(where: { $0.credentialReference == originalReference }) {
            try? repository.secrets.delete(reference: originalReference)
        }
    }
}
