import CryptoKit
import Foundation

// On-demand "what actually changed" insights for the git panel: one local
// `claude -p --model sonnet` run over a commit range's combined diff.
//
// Cost discipline, per design: a level is generated ONLY when the user clicks
// it, and results are cached forever on disk keyed by (commit hashes, level) —
// commits are immutable, so a cache hit can never go stale and repeat commits
// across sessions/branches are free.
final class GitInsights {
    static let shared = GitInsights()

    static var cacheDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Argus/git-insights", isDirectory: true)
    }

    // "v2": prompt revision — bumping regenerates insights written by older,
    // weaker prompts instead of serving them from cache forever.
    static func key(hashes: [String], level: String) -> String {
        let joined = "v2|" + hashes.joined(separator: ",") + "|" + level
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct Cached: Codable { let text: String; let cost: Double }

    func cached(_ key: String) -> Cached? {
        guard let d = try? Data(contentsOf: Self.cacheDir.appendingPathComponent(key + ".json"))
        else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: d)
    }

    private func store(_ key: String, _ c: Cached) {
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(c) {
            try? d.write(to: Self.cacheDir.appendingPathComponent(key + ".json"))
        }
    }

    enum Outcome {
        case ok(text: String, cost: Double, cached: Bool)
        case fail(String)
    }

    /// Generate (or return cached) insight for a commit range.
    /// `base` is the parent of the oldest selected commit (nil at a root); the
    /// diff is fetched from the owning broker, so this works for any machine.
    func generate(httpBase: String, dir: String, level: String,
                  hashes: [String], newest: String, base: String?,
                  metaLines: String) async -> Outcome {
        let key = Self.key(hashes: hashes, level: level)
        if let hit = cached(key) { return .ok(text: hit.text, cost: hit.cost, cached: true) }

        guard let diff = await fetchDiff(httpBase: httpBase, dir: dir,
                                         newest: newest, base: base, single: hashes.count == 1)
        else { return .fail("could not fetch the diff from the broker") }

        var diffText = String(decoding: diff, as: UTF8.self)
        let capBytes = 180_000
        if diffText.utf8.count > capBytes {
            diffText = String(diffText.prefix(capBytes)) + "\n\n[diff truncated at 180 KB — judge from what is shown]"
        }
        let input = "COMMITS IN THE SELECTED RANGE (newest first):\n" + metaLines +
            "\n\nCOMBINED DIFF (net effect, oldest → newest):\n" + diffText

        let folder = (dir as NSString).lastPathComponent
        let levelSpec: String
        switch level {
        case "brief":
            levelSpec = """
            LEVEL = BRIEF. At most 5 bullets. Each bullet must earn its place: what changed AND why \
            the reader should care — something they could not get from skimming `git log`. If exactly \
            one thing deserves their eye before building on this work, end with a single line: \
            "Look at: <file or thing> — <why>."
            """
        case "detailed":
            levelSpec = """
            LEVEL = DETAILED. Full reviewer notes. Walk each changed area (cluster of related files) \
            in order of importance: what changed, how it is implemented, and anything questionable \
            about the approach. Then a section "## Leftovers & risks": dead code, churn scars \
            (added-then-rewritten remnants), missing or hollow tests, silent behavior changes, \
            duplicated logic. End with "## Review order": a short numbered list — what to read \
            carefully first, what can be skimmed, what can be trusted blind.
            """
        default:
            levelSpec = """
            LEVEL = MEDIUM. About 200 words in three sections: "## What changed" (the net effect, by \
            area, concrete) · "## Intent" (what the agents were evidently trying to do — inferred \
            from the code, not from their commit messages) · "## Watch out" (specific risks and \
            leftovers, each anchored to a file or function).
            """
        }
        let prompt = """
        You are a senior engineer reviewing a batch of commits in the repository "\(folder)". Most or \
        all of the commits were written by CODING AGENTS working under light supervision. The reader \
        is the repository's owner: they did NOT watch this work happen, and they need to decide \
        whether it is sound and what to check before building on it.

        Input: the commit list (newest first) and the combined diff of the whole range — the NET \
        effect, with intermediate churn already collapsed.

        Rules:
        - Judge from the DIFF. Agent commit messages overstate and misdescribe; never repeat a claim \
        you cannot see in the code itself.
        - INSIGHT, not summary. "Refactored the buffer" is a summary. "The rollout buffer is now a \
        ring buffer, and the old drain-everything path is dead code that will mislead the next \
        reader" is insight. Every point must tell the reader something `git log` could not.
        - Be concrete: name files and functions. A flagged risk points at the exact place.
        - Call out agent tells plainly: dead ends left behind, defensive over-engineering, duplicated \
        logic, TODO/FIXME markers, deletions that look accidental, tests that assert nothing.
        - A small or trivial range gets one honest line, not an inflated report.
        - If the diff notes it was truncated, say what you could not verify.

        Format: plain English, markdown (## headings, - bullets, **bold** for names worth noticing). \
        The FIRST CHARACTER of your reply is the first character of the insight — no preamble, no \
        "Here's the review", no closing pleasantries, no "overall this is solid" filler.

        \(levelSpec)
        """

        guard let outer = await Self.runClaude(
            args: ["--dangerously-skip-permissions", "-p", prompt,
                   "--model", "sonnet", "--output-format", "json"],
            stdin: input)
        else { return .fail("claude did not produce output (timeout or non-zero exit)") }
        guard let env = Self.envelope(outer) else { return .fail("claude returned an error envelope") }

        store(key, Cached(text: env.result, cost: env.cost))
        return .ok(text: env.result, cost: env.cost, cached: false)
    }

    private func fetchDiff(httpBase: String, dir: String,
                           newest: String, base: String?, single: Bool) async -> Data? {
        guard let enc = dir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        var url = "\(httpBase)/git/diff?dir=\(enc)"
        if single || base == nil {
            url += "&scope=commit&hash=\(newest)"
        } else {
            url += "&scope=range&hash=\(newest)&hash2=\(base!)"
        }
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 60
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    // Same Process shape as the Command Center's runner (proven against the
    // same binary), plus a hard 4-minute kill so a wedged run can't leak.
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
                p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                let inPipe = Pipe(), outPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: killer)
                DispatchQueue.global(qos: .utility).async {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: p.terminationStatus == 0
                            ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }

    private static func envelope(_ outer: String) -> (result: String, cost: Double)? {
        struct Outer: Decodable { let result: String?; let is_error: Bool?; let total_cost_usd: Double? }
        guard let d = outer.data(using: .utf8),
              let o = try? JSONDecoder().decode(Outer.self, from: d),
              o.is_error != true, let r = o.result else { return nil }
        return (r, o.total_cost_usd ?? 0)
    }
}
