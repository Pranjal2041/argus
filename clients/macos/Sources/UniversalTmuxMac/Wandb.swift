import Foundation

/// One detected Weights & Biases run advertised by a session's output.
struct WandbRun: Identifiable, Hashable, Codable {
    let url: URL        // the full URL to open (kept verbatim, minus trailing punctuation)
    let runId: String   // path segment after `/runs/` — the dedup key
    let label: String   // run name if the output named it, else the run id
    /// When this run was first stored (drives the 7-day expiry). The detector leaves
    /// this at "now"; the persistent store preserves the ORIGINAL first-seen time when
    /// it merges a re-detection. Excluded from ==/hash so re-detecting the same run
    /// (with a fresh timestamp) doesn't read as a change in the scan loop.
    var discoveredAt: Date = Date()
    var id: String { runId }

    static func == (l: WandbRun, r: WandbRun) -> Bool {
        l.url == r.url && l.runId == r.runId && l.label == r.label
    }
    func hash(into h: inout Hasher) { h.combine(url); h.combine(runId); h.combine(label) }
}

/// Parses W&B run references out of terminal text. Deliberately a BATTERY of
/// independent matchers — W&B and the tools that wrap it advertise a run a dozen
/// different ways (and self-hosted instances use arbitrary hosts) — all run over
/// the same ANSI-stripped text, with results deduped by run id (latest wins on
/// label). Add a matcher here without touching anything else.
enum WandbDetector {
    /// All runs found in `text`, in first-seen order (so `.last` is the latest).
    static func runs(in rawText: String) -> [WandbRun] {
        let text = stripANSI(rawText)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var byId: [String: WandbRun] = [:]
        var order: [String] = []

        func consider(urlString: String, label rawLabel: String?, trustContext: Bool) {
            let cleaned = trimTrailing(urlString)
            guard let u = URL(string: cleaned), let id = runId(from: u) else { return }
            // Accept if the host is clearly W&B, or a captioned matcher already
            // proved the context ("View run … at: <url>" / a `wandb:` line).
            guard trustContext || isWandbHost(u) else { return }
            let label = rawLabel?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t'\"“”·•:"))
                .nilIfEmpty ?? id
            if byId[id] == nil { order.append(id) }
            // Keep a named label once we have one; otherwise take the freshest URL.
            if let existing = byId[id], existing.label != existing.runId, label == id {
                byId[id] = WandbRun(url: u, runId: id, label: existing.label)
            } else {
                byId[id] = WandbRun(url: u, runId: id, label: label)
            }
        }

        // (1) Captioned lines that NAME the run + give its URL — highest quality, and
        //     trusted regardless of host (covers self-hosted W&B). Captures the name.
        for re in namedMatchers {
            re.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m, m.numberOfRanges >= 3 else { return }
                let label = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
                consider(urlString: ns.substring(with: m.range(at: 2)), label: label, trustContext: true)
            }
        }

        // (2) Any URL sitting on a `wandb:` / `W&B` line — trusted (the CLI prefixes
        //     every line with `wandb:`); covers self-hosted hosts with no run name.
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            guard lower.contains("wandb:") || lower.contains("w&b") || lower.contains("weights & biases") else { continue }
            for url in urls(in: line) { consider(urlString: url, label: nil, trustContext: true) }
        }

        // (3) Bare URLs anywhere — only trusted when the host itself is W&B.
        for url in urls(in: text) { consider(urlString: url, label: nil, trustContext: false) }

        return order.compactMap { byId[$0] }
    }

    // MARK: matchers

    private static let urlRe = regex(#"https?://[^\s"'<>)\]\}]+"#)

    /// "View run <name> at: <url>", "Synced <name>: <url>", "Run page: <url>",
    /// "Syncing run <name> to <url>", "View project/sweep/run at: <url>".
    private static let namedMatchers: [NSRegularExpression] = [
        regex(#"(?i)(?:🚀\s*)?view run\s+(.+?)\s+at:?\s*(https?://[^\s"'<>)\]\}]+)"#),
        regex(#"(?i)synced\s+(.+?):\s*(https?://[^\s"'<>)\]\}]+)"#),
        regex(#"(?i)syncing run\s+(.+?)\s+to\s*(https?://[^\s"'<>)\]\}]+)"#),
        regex(#"(?i)(?:run page|view project at|view sweep at|view run at)\s*:?\s*()(https?://[^\s"'<>)\]\}]+)"#),
    ]

    private static func urls(in s: String) -> [String] {
        let ns = s as NSString
        return urlRe.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func isWandbHost(_ u: URL) -> Bool {
        let host = (u.host ?? "").lowercased()
        if host == "wandb.ai" || host.hasSuffix(".wandb.ai") || host.contains("wandb") { return true }
        // self-hosted with the canonical /<entity>/<project>/runs/<id> shape
        let segs = u.path.split(separator: "/")
        if let ri = segs.firstIndex(of: "runs"), ri >= 2, ri + 1 < segs.count { return true }
        return false
    }

    private static func runId(from u: URL) -> String? {
        let segs = u.path.split(separator: "/").map(String.init)
        guard let ri = segs.firstIndex(of: "runs"), ri + 1 < segs.count else { return nil }
        let id = segs[ri + 1]
        return id.isEmpty ? nil : id
    }

    private static func trimTrailing(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, ".,;:!?)]}'\"”’>".contains(last) { t = t.dropLast() }
        return String(t)
    }

    /// Strip ANSI/VT escape sequences (CSI colors, OSC) by hand — so a run id
    /// printed in a different color rejoins its URL into one contiguous token.
    /// Done in code (not regex) to avoid ICU escape pitfalls with the ESC byte.
    private static func stripANSI(_ s: String) -> String {
        let esc: Unicode.Scalar = "\u{1B}", bel: Unicode.Scalar = "\u{07}"
        var out = String.UnicodeScalarView()
        var i = s.unicodeScalars.makeIterator()
        while let c = i.next() {
            guard c == esc else { out.append(c); continue }
            guard let n = i.next() else { break }
            if n == "[" {                                  // CSI: … final byte @–~
                while let p = i.next() { if p.value >= 0x40 && p.value <= 0x7E { break } }
            } else if n == "]" {                           // OSC: … BEL or ST (ESC \)
                while let p = i.next() {
                    if p == bel { break }
                    if p == esc { _ = i.next(); break }
                }
            }                                              // else: 2-char ESC — n already consumed
        }
        return String(out)
    }

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p)   // compile-time constant patterns
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
