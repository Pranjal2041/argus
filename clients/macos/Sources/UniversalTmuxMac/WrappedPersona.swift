import Foundation

/// The one part of Argus Wrapped that is NOT pure arithmetic. Every number is real
/// and computed by WrappedStats; this asks the selected agent to READ those numbers and
/// name the kind of commander they describe — a vivid persona + a short second-person
/// narrative for the finale. Falls back to the rule-based archetype if the CLI is
/// missing or the call fails.
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

    /// Ask the selected agent for a persona. Returns nil on failure (caller falls back).
    static func generate(stats: [String: Any]) async -> Persona? {
        guard let result = try? await AgentCLIRunner().run(AgentGenerationRequest(
                provider: AgentTaskPurpose.wrappedPersona.selectedProvider(), purpose: .wrappedPersona,
                prompt: systemPrompt + "\n\n" + digest(stats)
              )),
              let json = extractJSON(result.text),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty,
              let blurb = obj["blurb"] as? String else { return nil }
        return Persona(name: name, blurb: blurb, narrative: (obj["narrative"] as? String) ?? "")
    }

    /// Strip code fences / prose and return the first {...} object.
    private static func extractJSON(_ s: String) -> String? {
        guard let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}"), lo < hi else { return nil }
        return String(s[lo...hi])
    }
}
