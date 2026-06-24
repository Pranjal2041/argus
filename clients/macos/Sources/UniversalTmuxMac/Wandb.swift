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
            guard let u = URL(string: cleaned) else { return }
            // Accept if the host is clearly W&B, or a captioned matcher already
            // proved the context ("View run … at: <url>" / a `wandb:` line).
            guard trustContext || isWandbHost(u) else { return }
            // Validate the run id: recover it from any trailing text glued on with no
            // space, reject truncations/junk, and rebuild a canonical run URL so even a
            // mangled capture opens the right run.
            guard let raw = rawRunId(from: u), let id = normalizedRunId(raw),
                  let url = canonicalRunURL(from: u, id: id) else { return }
            let label = rawLabel?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t'\"“”·•:"))
                .nilIfEmpty ?? id
            if byId[id] == nil { order.append(id) }
            // Keep a named label once we have one; otherwise take the freshest URL.
            if let existing = byId[id], existing.label != existing.runId, label == id {
                byId[id] = WandbRun(url: url, runId: id, label: existing.label)
            } else {
                byId[id] = WandbRun(url: url, runId: id, label: label)
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

        return dropTruncations(order.compactMap { byId[$0] })
    }

    /// Re-validate an already-stored list with the current rules (recovers ids, rebuilds
    /// canonical URLs, drops junk + truncations, dedups) — used to clean the persisted
    /// store on load and after each merge, so historical false positives disappear without
    /// a manual clear. Preserves each run's earliest first-seen time and its best label.
    static func sanitize(_ runs: [WandbRun]) -> [WandbRun] {
        var byId: [String: WandbRun] = [:]
        var order: [String] = []
        for r in runs {
            guard let raw = rawRunId(from: r.url), let id = normalizedRunId(raw),
                  let url = canonicalRunURL(from: r.url, id: id) else { continue }
            let label = (r.label != r.runId && !r.label.isEmpty) ? r.label : id
            if byId[id] == nil { order.append(id) }
            if let ex = byId[id] {
                byId[id] = WandbRun(url: url, runId: id,
                                    label: ex.label != id ? ex.label : label,
                                    discoveredAt: min(ex.discoveredAt, r.discoveredAt))
            } else {
                byId[id] = WandbRun(url: url, runId: id, label: label, discoveredAt: r.discoveredAt)
            }
        }
        return dropTruncations(order.compactMap { byId[$0] })
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
        // self-hosted with the canonical /<entity>/<project>/runs/<id> shape — `runs` must
        // be exactly the third path segment, so a CI URL like
        // github.com/<o>/<r>/actions/runs/<n> (runs deeper) is NOT mistaken for a W&B run.
        let segs = u.path.split(separator: "/")
        if let ri = segs.firstIndex(of: "runs"), ri == 2, ri + 1 < segs.count { return true }
        return false
    }

    /// The raw path segment after `/runs/` — may be mangled (glued to following text, or
    /// truncated); `normalizedRunId` cleans and validates it.
    private static func rawRunId(from u: URL) -> String? {
        let segs = u.path.split(separator: "/").map(String.init)
        guard let ri = segs.firstIndex(of: "runs"), ri + 1 < segs.count else { return nil }
        let id = segs[ri + 1]
        return id.isEmpty ? nil : id
    }

    /// A W&B run id is a token of `[A-Za-z0-9]` (plus `-`/`_` for custom ids). Two failure
    /// modes show up in real terminal output: the URL gets glued to a following word with
    /// no space ("…/runs/r9egz1t7—that"), and it gets split/truncated by a line-wrap or a
    /// stray color code ("…/runs/5512f5" of `5512f5bf`). Cut at the first illegal character
    /// to recover the id from the first case, then require W&B's generated-id length (8) to
    /// reject the second. Truncations that survive (a prefix of a longer real id) are
    /// dropped by `dropTruncations`.
    private static func normalizedRunId(_ raw: String) -> String? {
        var id = ""
        for ch in raw {
            if ch == "-" || ch == "_" || (ch.isASCII && (ch.isLetter || ch.isNumber)) { id.append(ch) }
            else { break }
        }
        return id.count >= 8 ? id : nil
    }

    /// Rebuild a clean `scheme://host/<entity>/<project>/runs/<id>` URL from a (possibly
    /// mangled) capture, dropping any junk path/query that got glued on, so the run still
    /// opens correctly.
    private static func canonicalRunURL(from u: URL, id: String) -> URL? {
        let segs = u.path.split(separator: "/").map(String.init)
        guard let ri = segs.firstIndex(of: "runs") else { return nil }
        var comps = URLComponents()
        comps.scheme = u.scheme
        comps.host = u.host
        comps.port = u.port
        comps.path = "/" + (segs[0...ri] + [id]).joined(separator: "/")
        return comps.url
    }

    /// Drop ids that are a strict prefix of another detected id in the SAME project — the
    /// signature of a truncated URL ("5512f5" alongside "5512f5bf"). Real 8-char W&B ids
    /// being prefixes of one another is vanishingly unlikely, so this only removes
    /// truncations, never a legitimate run.
    private static func dropTruncations(_ runs: [WandbRun]) -> [WandbRun] {
        func project(_ r: WandbRun) -> URL { r.url.deletingLastPathComponent() }
        return runs.filter { a in
            !runs.contains { b in
                b.runId != a.runId && b.runId.hasPrefix(a.runId) && project(b) == project(a)
            }
        }
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
