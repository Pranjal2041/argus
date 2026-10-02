import Foundation

@available(macOS 14.0, *)
struct CodexLogin: Sendable {
    var profile: String
    var email: String
}

@available(macOS 14.0, *)
enum CodexLoginMethod: String, CaseIterable, Sendable {
    case browser, deviceCode
    var title: String { self == .browser ? "UT Browser" : "Device code" }
}

@available(macOS 14.0, *)
struct CodexLoginInstructions: Sendable {
    var url: URL
    var userCode: String?
    var browserOpened: Bool
}

/// Provider-owned authentication, usable by the CLI probe without launching the app.
/// OAuth and token refresh belong to Codex. The client chooses the sign-in UX.
@available(macOS 14.0, *)
struct CodexAuthenticator: Sendable {
    var executable: String
    var browser: any BrowserOpening = DefaultBrowserOpener()
    var makeSession: @Sendable (String, String) throws -> any CodexServing = {
        try CodexRPCSession(executable: $0, profile: $1)
    }

    func signIn(profile: String, existingEmails: Set<String>, method: CodexLoginMethod = .browser,
                onInstructions: @Sendable (CodexLoginInstructions) async -> Void = { _ in }) async throws -> CodexLogin {
        let original = URL(fileURLWithPath: profile, isDirectory: true)
        let hasExistingAuth = FileManager.default.fileExists(atPath: original.appendingPathComponent("auth.json").path)
        let loginProfile = hasExistingAuth
            ? IntegrationConfiguration.directory.appendingPathComponent("profiles/reconnect-\(UUID().uuidString)", isDirectory: true)
            : original
        try FileManager.default.createDirectory(at: loginProfile, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let session = try makeSession(executable, loginProfile.path)
        defer { session.close(with: CancellationError()) }
        try await session.initialize()
        let start: JSONValue
        do {
            start = try await session.request("account/login/start", params: ["type": .string(method == .browser ? "chatgpt" : "chatgptDeviceCode")], timeout: 25)
        } catch IntegrationError.authentication {
            throw IntegrationError.authentication(method == .deviceCode
                ? "Could not start device-code sign-in. Enable device-code login in ChatGPT security settings or workspace permissions, and use a current Codex CLI. You can also choose Default browser."
                : "Could not start browser sign-in. Try Device code or check the Codex CLI installation.")
        }
        guard let address = start[method == .browser ? "authUrl" : "verificationUrl"].string,
              let url = URL(string: address), url.scheme == "https",
              url.user == nil, url.password == nil, (url.port == nil || url.port == 443),
              ["auth.openai.com", "chatgpt.com"].contains(url.host ?? "") else {
            throw IntegrationError.invalidResponse("Codex did not return a valid sign-in URL.")
        }
        let code = method == .deviceCode ? start["userCode"].string : nil
        if method == .deviceCode && (code?.isEmpty != false) {
            throw IntegrationError.invalidResponse("Codex did not return a device authorization code. Try browser sign-in.")
        }
        let opened = method == .browser ? await browser.open(url) : false
        // A blocked browser launch still leaves a usable copyable link in the app.
        await onInstructions(CodexLoginInstructions(url: url, userCode: code, browserOpened: opened))
        let completed = try await session.waitForNotification("account/login/completed", timeout: 600)
        guard completed["success"].bool == true else {
            throw IntegrationError.authentication("Sign-in did not complete. You can try again.")
        }
        let account = try await session.request("account/read", params: ["refreshToken": .bool(false)], timeout: 25)["account"]
        guard account["type"].string == "chatgpt", let email = account["email"].string, !email.isEmpty else {
            throw IntegrationError.authentication("Sign-in did not return a ChatGPT account identity.")
        }
        guard !existingEmails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw IntegrationError.authentication("That account is already connected. Sign in again and choose a different account in your browser.")
        }
        return CodexLogin(profile: loginProfile.path, email: email)
    }

    /// Re-read before committing so a long sign-in cannot overwrite unrelated config edits.
    static func save(_ login: CodexLogin, sourceID: String, originalProfile: String,
                     to url: URL = IntegrationConfiguration.file) throws {
        try AccountProfileCommit.save(VerifiedProfileLogin(profile: login.profile, identity: login.email),
            sourceID: sourceID, integration: .codex, originalProfile: originalProfile,
            repository: ConnectionRepository(url: url))
    }
}
