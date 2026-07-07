import Foundation

/// The one part of Argus Wrapped that is NOT pure arithmetic. Every number is real
/// and computed by WrappedStats; this asks Claude (haiku) to READ those numbers and
/// name the kind of commander they describe — a vivid persona + a short second-person
/// narrative for the finale. Falls back to the rule-based archetype if the CLI is
/// missing or the call fails. Mirrors CommandCenter's `claude -p` invocation.
enum WrappedPersona {
    struct Persona: Codable { let name: String; let blurb: String; let narrative: String }

    /// A compact, model-friendly digest of the salient numbers.
    static func digest(_ stats: [String: Any]) -> String {
        func i(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? Int) ?? 0 }
        let t = stats["totals"] as? [String: Any]
        let r = stats["rhythm"] as? [String: Any]
        let sm = stats["statusMix"] as? [String: Int] ?? [:]
        let dg = stats["delegation"] as? [String: Any]
        let w = stats["window"] as? [String: Any]
        var l: [String] = []
        l.append("window: \(i(w, "activeDays")) active days out of \(i(w, "spanDays"))")
        l.append("you sent \(i(t, "utterances")) messages (\(i(t, "chars")) chars) to your agents")
        l.append("fleet: \(i(t, "agents")) agents across \(i(t, "machines")) machines; \(i(t, "sessionsNew")) spawned, \(i(t, "sessionsKilled")) retired")
        l.append("rhythm: night_score=\(i(r, "nightScore"))% peak_hour=\(i(r, "peakHour"))h")
        l.append("delegation ratio=\((dg?["ratio"] as? Double) ?? 0)x (agents worked \(i(dg, "agentWorkingMin"))min vs your \(i(dg, "activeMin"))min typing)")
        l.append("attention: watched agents \(i(t, "viewedMinutes"))min; \(i(t, "phoneMsgs")) messages from phone")
        l.append("fleet state: working=\(sm["working"] ?? 0) needs-your-decision=\(sm["needs-decision"] ?? 0) stuck=\(sm["stuck"] ?? 0) idle=\(sm["idle"] ?? 0) milestones=\(sm["milestone"] ?? 0)")
        l.append("research: \(i(t, "wandbRuns")) experiments, \(i(t, "gitPanels")) git diffs opened, \(i(t, "workflows")) workflows")
        if let p = stats["projects"] as? [[String: Any]], !p.isEmpty {
            l.append("top projects: " + p.prefix(5).compactMap { $0["name"] as? String }.joined(separator: ", "))
        }
        if let a = stats["agents"] as? [[String: Any]], !a.isEmpty {
            l.append("top agents: " + a.prefix(5).compactMap { $0["session"] as? String }.joined(separator: ", "))
        }
        if let cw = stats["catchphrase"] as? [String: Any], let word = cw["word"] as? String {
            l.append("most common opening word: \"\(word)\" (\(i(cw, "count")) times)")
        }
        return l.joined(separator: "\n")
    }

    static let systemPrompt = """
    You write the finale of "Argus Wrapped", a Spotify-Wrapped-style recap for someone who commands a FLEET of AI coding agents across many machines (laptop, GPU cluster, a Windows box, even their phone). You are given real stats for a time window. Read them and name the kind of commander they describe.

    Rules:
    - Be specific and grounded in the numbers. Reference what actually stands out (e.g. heavy delegation, night hours, many machines, phone use, lots of experiments). Never invent facts not implied by the stats.
    - Be sharp and a little playful. Never generic, never corporate, never cheesy. No emoji.
    - The narrative is second person ("you"), ~40 words, celebratory but earned.
    - Respond with ONLY minified JSON, no prose, no code fences:
    {"name":"The <2-3 word title>","blurb":"<one punchy line, <=80 chars>","narrative":"<2-3 sentences, ~40 words>"}
    """

    /// Ask Claude for a persona. Returns nil on any failure (caller falls back).
    static func generate(stats: [String: Any]) async -> Persona? {
        let args = ["-p", "--model", "haiku", "--output-format", "json", "--system-prompt", systemPrompt]
        guard let raw = await runClaude(args: args, stdin: digest(stats)),
              let result = envelope(raw),
              let json = extractJSON(result),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty,
              let blurb = obj["blurb"] as? String else { return nil }
        return Persona(name: name, blurb: blurb, narrative: (obj["narrative"] as? String) ?? "")
    }

    // MARK: claude invocation (GUI apps don't inherit a login shell's PATH)

    private static let claudePath: String = {
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          NSHomeDirectory() + "/.claude/local/claude",
                          NSHomeDirectory() + "/.local/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "/opt/homebrew/bin/claude" : out
    }()

    private static func runClaude(args: [String], stdin: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claudePath)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory()) // no project CLAUDE.md
                let inPipe = Pipe(), outPipe = Pipe()
                p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                DispatchQueue.global(qos: .utility).async {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }

    /// Pull the `result` field out of `--output-format json`.
    private static func envelope(_ outer: String) -> String? {
        struct Outer: Decodable { let result: String?; let is_error: Bool? }
        guard let d = outer.data(using: .utf8), let o = try? JSONDecoder().decode(Outer.self, from: d),
              o.is_error != true, let r = o.result else { return nil }
        return r
    }

    /// Strip code fences / prose and return the first {...} object.
    private static func extractJSON(_ s: String) -> String? {
        guard let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}"), lo < hi else { return nil }
        return String(s[lo...hi])
    }
}
