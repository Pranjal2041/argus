import Foundation

@available(macOS 14.0, *)
struct DevinAccount: Sendable {
    var email: String
    var plan: String?

    static func parse(_ output: String) throws -> Self {
        let text = DevinOutput.plain(output)
        guard text.localizedCaseInsensitiveContains("Logged in"), !text.localizedCaseInsensitiveContains("Not logged in"),
              let email = DevinOutput.captures("(?im)^\\s*Email:\\s*(\\S+@\\S+)\\s*$", text).first else {
            throw IntegrationError.authentication("Devin did not confirm this account's identity. Sign in again in Connections.")
        }
        return Self(email: email, plan: DevinOutput.captures("(?im)^\\s*Plan:\\s*(.+)$", text).first)
    }
}

@available(macOS 14.0, *)
enum DevinOutput {
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\x1B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }
    static func captures(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    static func loginURL(in text: String) -> URL? {
        var candidates = text.components(separatedBy: .whitespacesAndNewlines)
        // Output arrives in fragments. A URL is not complete until a delimiter
        // follows it; never open a truncated PKCE URL from an early chunk.
        if text.last.map({ !$0.isWhitespace }) == true { candidates.removeLast() }
        for candidate in candidates {
            guard let url = URL(string: candidate), url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  let host = url.host?.lowercased(),
                  host == "app.devin.ai" || host.hasSuffix(".devinenterprise.com"),
                  url.path == "/auth/cli/continue" else { continue }
            let queries = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard ["state", "code_challenge"].allSatisfy({ key in queries.contains { $0.name == key && $0.value?.isEmpty == false } }),
                  queries.contains(where: { $0.name == "code_challenge_method" && $0.value == "S256" }) else { continue }
            return url
        }
        return nil
    }
}

/// The CLI owns PKCE, token exchange and enterprise routing. It signs into a new
/// owned profile and remains alive while the user pastes the code into Argus.
@available(macOS 14.0, *)
struct DevinAuthenticator: Sendable {
    var executable: String
    var runner: any CommandRunning = CommandRunner()
    var makeSession: @Sendable (String, [String: String]) -> any LoginProcessServing = {
        InteractiveLoginProcess(executable: $0, arguments: ["auth", "login", "--force-manual-token-flow"], environment: $1)
    }

    func signIn(profile: AccountProfile,
                onInstructions: @Sendable (URL, any LoginProcessServing) async -> Void) async throws -> VerifiedProfileLogin {
        let session = makeSession(executable, profile.environment)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try session.start()
                var transcript = Data(), sentInstructions = false, exitStatus: Int32?
                for try await event in session.events {
                    try Task.checkCancellation()
                    switch event {
                    case .output(let data):
                        if !sentInstructions {
                            transcript.append(data)
                            guard transcript.count < 64 * 1024 else { throw IntegrationError.invalidResponse("Devin did not provide a readable sign-in link.") }
                            if let url = DevinOutput.loginURL(in: DevinOutput.plain(String(decoding: transcript, as: UTF8.self))) {
                                sentInstructions = true; transcript = Data()
                                await onInstructions(url, session)
                            }
                        }
                    case .exited(let status): exitStatus = status
                    }
                }
                guard sentInstructions, exitStatus == 0 else {
                    throw IntegrationError.authentication("Devin sign-in did not complete. Start a new sign-in and use its new code. The existing account is unchanged.")
                }
                // A successful login and a reported quota are independent. An
                // enterprise account can be connected without a readable limit.
                let result = try await runner.run(executable: executable, arguments: ["auth", "status"], environment: profile.environment, timeout: 30)
                guard result.status == 0 else { throw IntegrationError.authentication("Devin could not verify the signed-in account.") }
                let account = try DevinAccount.parse(String(decoding: result.stdout + result.stderr, as: UTF8.self))
                let credentials = profile.root.appendingPathComponent("data/devin/credentials.toml")
                guard FileManager.default.fileExists(atPath: credentials.path) else { throw IntegrationError.authentication("Devin did not save a login in this account's private profile.") }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentials.path)
                try Task.checkCancellation()
                await session.close()
                return VerifiedProfileLogin(profile: profile.root.path, identity: account.email)
            } catch {
                await session.close()
                throw error
            }
        } onCancel: { session.cancel() }
    }
}
