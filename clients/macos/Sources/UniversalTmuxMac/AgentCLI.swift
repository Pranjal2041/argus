import Foundation

struct AgentGenerationRequest {
    let provider: AgentProvider
    let purpose: AgentTaskPurpose
    let prompt: String
    var conversation: AgentConversation? = nil
    var directory: URL? = nil
    var imageURL: URL? = nil
    var timeout: TimeInterval = 90
    var diagnosticsPrefix: URL? = nil
}

struct AgentGenerationResult {
    let provider: AgentProvider
    let text: String
    let conversation: AgentConversation?
    let costUSD: Double
}

enum AgentCLIError: LocalizedError {
    case providerMismatch, invalidConversation, missingResult, oversizedResult, unsupportedCapability
    case failed(AgentProvider, Int32, String)
    case executableMissing(AgentProvider)
    var errorDescription: String? {
        switch self {
        case .providerMismatch: return "A conversation cannot be resumed with a different agent provider."
        case .invalidConversation: return "The agent did not report the expected conversation identity."
        case .missingResult: return "The agent did not produce a final answer."
        case .oversizedResult: return "The agent result exceeds the output limit."
        case .unsupportedCapability: return "This agent does not support the required execution capability."
        case .failed(let provider, let status, let detail): return "\(provider.displayName) exited with status \(status). \(detail)"
        case .executableMissing(let provider): return "\(provider.displayName) CLI is not installed."
        }
    }
}

/// All callers share identity validation, bounded process lifetime/output,
/// isolated control files and final-answer extraction. Adapters only translate
/// argv and output formats; no feature parses another provider's output.
struct AgentCLIRunner {
    var executableOverride: URL? = nil
    static let maximumResultBytes = 32 * 1024 * 1024

    func run(_ request: AgentGenerationRequest) async throws -> AgentGenerationResult {
        guard request.purpose.supportedProviders.contains(request.provider) else { throw AgentCLIError.unsupportedCapability }
        if let conversation = request.conversation {
            guard conversation.provider == request.provider else { throw AgentCLIError.providerMismatch }
            guard request.provider.isValidSessionID(conversation.id) else { throw AgentCLIError.invalidConversation }
        }
        let executable = try executableOverride ?? Self.executable(for: request.provider)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("argus-agent-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        // The working directory and permission scopes must name the same real
        // location, including when the caller uses a symlinked workspace.
        let directory = (request.directory ?? temporary).resolvingSymlinksInPath()
        let finalURL = temporary.appendingPathComponent("final.txt")
        let exportURL = temporary.appendingPathComponent("conversation.json")
        let promptURL = temporary.appendingPathComponent("prompt.txt")
        let configURL = temporary.appendingPathComponent("config.json")
        var prompt = request.prompt
        if request.provider == .devin && request.purpose.writesWorkspace {
            // Devin's direct edit/write tools are outside its OS sandbox and
            // require interactive approval. Advertise the supported executor
            // instead; all file mutations remain inside the sandboxed shell.
            prompt = "Execution environment: this is an unattended OS-sandboxed workspace. Use the exec tool for all file creation and edits (including generating reports and other artifacts). Direct write/edit tools and MCP tools are unavailable.\n\n" + prompt
        }
        if let image = request.imageURL, request.provider != .codex {
            prompt += "\n\nInspect the attached image at this local path: \(image.path)"
        }
        try Data(prompt.utf8).write(to: promptURL, options: .atomic)
        if request.provider == .devin {
            let config = Self.devinConfiguration(writesWorkspace: request.purpose.writesWorkspace,
                                                 directory: directory, userConfiguration: Self.devinUserConfiguration())
            try JSONSerialization.data(withJSONObject: config, options: .sortedKeys).write(to: configURL, options: .atomic)
        }
        let arguments = Self.arguments(request, directory: directory, finalURL: finalURL,
                                       exportURL: exportURL, promptURL: promptURL, configURL: configURL)
        let output = try await BoundedProcessRunner(timeout: request.timeout, maximumOutputBytes: Self.maximumResultBytes)
            .run(executable: executable, arguments: arguments, input: request.provider == .devin ? Data() : Data(prompt.utf8),
                 directory: directory, environment: Self.environment())
        if let prefix = request.diagnosticsPrefix {
            try output.stdout.write(to: prefix.appendingPathExtension(request.provider == .codex ? "jsonl" : "stdout.log"), options: .atomic)
            try output.stderr.write(to: prefix.appendingPathExtension("stderr.log"), options: .atomic)
        }
        guard output.status == 0 else {
            throw AgentCLIError.failed(request.provider, output.status, String(decoding: output.stderr.suffix(4000), as: UTF8.self))
        }
        let result: AgentGenerationResult
        switch request.provider {
        case .codex:
            let text = String(decoding: try Self.readBounded(finalURL), as: UTF8.self)
            let id = Self.codexSessionID(in: String(decoding: output.stdout, as: UTF8.self))
            result = AgentGenerationResult(provider: .codex, text: text,
                conversation: id.map { AgentConversation(provider: .codex, id: $0) } ?? request.conversation, costUSD: 0)
        case .claude:
            result = try Self.claudeResult(output.stdout)
        case .devin:
            result = try Self.devinResult(try Self.readBounded(exportURL))
        }
        return try Self.validate(result, for: request)
    }

    static func validate(_ result: AgentGenerationResult, for request: AgentGenerationRequest) throws -> AgentGenerationResult {
        guard result.provider == request.provider else { throw AgentCLIError.providerMismatch }
        if let conversation = result.conversation {
            guard conversation.provider == request.provider, request.provider.isValidSessionID(conversation.id) else {
                throw AgentCLIError.invalidConversation
            }
        }
        if let expected = request.conversation, result.conversation != expected { throw AgentCLIError.invalidConversation }
        if request.purpose.needsConversation && result.conversation == nil { throw AgentCLIError.invalidConversation }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentCLIError.missingResult }
        return result
    }

    static func arguments(_ request: AgentGenerationRequest, directory: URL, finalURL: URL,
                          exportURL: URL, promptURL: URL, configURL: URL) -> [String] {
        let resume = request.conversation?.id
        switch request.provider {
        case .codex:
            var args = ["exec"] + (resume == nil ? [] : ["resume"])
            if !request.purpose.writesWorkspace { args += ["--ignore-user-config", "--ignore-rules"] }
            args += ["--skip-git-repo-check"]
            if resume == nil {
                args += ["--sandbox", request.purpose.writesWorkspace ? "workspace-write" : "read-only", "--color", "never", "-C", directory.path]
                if !request.purpose.needsConversation { args += ["--ephemeral"] }
            }
            if let model = request.purpose.model(for: .codex) { args += ["-m", model] }
            args += ["-c", "model_reasoning_effort=\"\(request.purpose.reasoningEffort)\"", "--json", "-o", finalURL.path]
            if let image = request.imageURL { args += ["-i", image.path] }
            if let resume { args += [resume] }
            return args + ["-"]
        case .claude:
            var args = ["-p", "--output-format", "json"]
            if let model = request.purpose.model(for: .claude) { args += ["--model", model] }
            if request.purpose.writesWorkspace {
                args += ["--permission-mode", "acceptEdits"]
            } else {
                args += ["--tools", request.imageURL == nil ? "" : "Read", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", ""]
                if let image = request.imageURL { args += ["--allowedTools", "Read(\(image.path))"] }
            }
            if let resume { args += ["--resume", resume] }
            return args
        case .devin:
            var args = ["--print", "--prompt-file", promptURL.path, "--export", exportURL.path,
                        "--config", configURL.path, "--respect-workspace-trust", "false"]
            if request.purpose.writesWorkspace { args += ["--sandbox", "--permission-mode", "autonomous"] }
            else { args += ["--permission-mode", "auto"] }
            if let resume { args += ["--resume", resume] }
            return args
        }
    }

    static func devinConfiguration(writesWorkspace: Bool, directory: URL,
                                   userConfiguration: [String: Any] = [:]) -> [String: Any] {
        var config: [String: Any] = ["auto_update": false, "notify": "never", "subagents_enabled": false]
        // Preserve the user's model and connectivity settings while defining
        // permissions for this invocation only. Never alter the installed config.
        for key in ["agent", "proxy"] { config[key] = userConfiguration[key] }
        var sandbox: [String: Any] = ["excluded": ["deny": ["Exec(**)"]]]
        let originalSandbox = userConfiguration["sandbox"] as? [String: Any] ?? [:]
        for key in ["allowed_domains", "denied_domains", "network_mode"] { sandbox[key] = originalSandbox[key] }
        config["sandbox"] = sandbox
        if writesWorkspace {
            config["permissions"] = ["allow": ["Write(\(directory.path)/**)"], "deny": ["write", "edit", "mcp__*"]]
        } else {
            config["permissions"] = ["deny": ["Write(/**)", "edit", "exec", "mcp__*", "Fetch(*)"]]
            config["read_config_from"] = Dictionary(uniqueKeysWithValues:
                ["agents_standard", "cursor", "windsurf", "claude", "copilot", "opencode", "zed"].map { ($0, false) })
        }
        return config
    }

    private static func devinUserConfiguration() -> [String: Any] {
        let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        let url = URL(fileURLWithPath: root).appendingPathComponent("devin/config.json")
        guard let data = try? readBounded(url),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else { return [:] }
        return object
    }

    static func claudeResult(_ data: Data) throws -> AgentGenerationResult {
        struct Envelope: Decodable {
            let result: String?
            let is_error: Bool?
            let session_id: String?
            let total_cost_usd: Double?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.is_error != true, let text = envelope.result else { throw AgentCLIError.missingResult }
        return AgentGenerationResult(provider: .claude, text: text,
            conversation: envelope.session_id.map { AgentConversation(provider: .claude, id: $0) },
            costUSD: envelope.total_cost_usd ?? 0)
    }

    static func codexSessionID(in jsonl: String) -> String? {
        for line in jsonl.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "thread.started", let id = object["thread_id"] as? String,
                  AgentProvider.codex.isValidSessionID(id) else { continue }
            return id
        }
        return nil
    }

    static func devinResult(_ data: Data) throws -> AgentGenerationResult {
        struct Export: Decodable {
            struct Step: Decodable { let source: String; let message: String?; let tool_calls: [DiscardJSON]? }
            let schema_version: String
            let session_id: String
            let steps: [Step]
        }
        let export = try JSONDecoder().decode(Export.self, from: data)
        guard export.schema_version.hasPrefix("ATIF-"), AgentProvider.devin.isValidSessionID(export.session_id) else {
            throw AgentCLIError.invalidConversation
        }
        var parts: [String] = [], finals: [String] = []
        for step in export.steps {
            if step.source == "user" { parts = []; finals = []; continue }
            guard step.source == "agent", let text = step.message, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            parts.append(text)
            if step.tool_calls?.isEmpty != false { finals.append(text) }
        }
        return AgentGenerationResult(provider: .devin, text: (finals.isEmpty ? parts : finals).joined(separator: "\n\n"),
            conversation: AgentConversation(provider: .devin, id: export.session_id), costUSD: 0)
    }

    /// Tool payloads need not be decoded or retained to distinguish commentary.
    private struct DiscardJSON: Decodable { init(from decoder: Decoder) throws {} }

    private static func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumResultBytes + 1) ?? Data()
        guard data.count <= maximumResultBytes else { throw AgentCLIError.oversizedResult }
        return data
    }

    static func executable(for provider: AgentProvider) throws -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.claude/local"]
        for path in paths where !path.isEmpty {
            let url = URL(fileURLWithPath: path).appendingPathComponent(provider.rawValue)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw AgentCLIError.executableMissing(provider)
    }

    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let current = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (current + [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }
}
