import Foundation

/// Argus Wrapped's compute engine. It is a PURE function of the activity-journal
/// event stream: it reads every YYYY-MM-DD.jsonl the journal has written, and
/// derives every card/graph from those events for a requested window. Nothing is
/// hardcoded and nothing is hand-curated — open it today and it summarizes today's
/// data; open it in December and it summarizes the year; a different user gets
/// theirs. All timestamps are stored UTC and converted to the user's local zone
/// here, so "night owl" / hour-of-day framing is honest.
enum WrappedStats {

    /// Compute the full stats blob for a window. `days == 0` means "all time".
    static func compute(days: Int) -> [String: Any] {
        let events = loadEvents()
        let cal = Calendar.current
        let now = Date()
        let cutoff = days > 0 ? cal.date(byAdding: .day, value: -days, to: now) : nil
        let evs = events.filter { e in
            guard let d = e.date else { return false }
            if let c = cutoff { return d >= c }
            return true
        }
        guard !evs.isEmpty else { return ["empty": true] }

        var out: [String: Any] = [:]
        out["generatedAt"] = ISO8601DateFormatter().string(from: now)

        // ---- window ----
        let dates = evs.compactMap { $0.date }
        let first = dates.min()!, last = dates.max()!
        let activeDays = Set(evs.compactMap { $0.localDay })
        out["window"] = [
            "startDay": localDayString(first), "endDay": localDayString(last),
            "spanDays": (cal.dateComponents([.day], from: cal.startOfDay(for: first), to: cal.startOfDay(for: last)).day ?? 0) + 1,
            "activeDays": activeDays.count,
        ]

        let utter = evs.filter { $0.kind == "utterance" }
        let saidUtter = utter.filter { !($0.bool("redacted")) && !($0.str("said").isEmpty) }
        func k(_ kind: String) -> [Event] { evs.filter { $0.kind == kind } }

        // ---- canonical W&B run ids ----
        // The run detector sometimes records a real id with trailing prose appended
        // (e.g. "57991255underthesamelst-pi-rl"). Such an id is a strict extension of a
        // shorter real id, so treat it as an artifact and keep only the shorter real one.
        let allRunIds = Set(k("wandbRun").compactMap { $0.strOrNil("runId") })
        func isCanonicalRun(_ id: String) -> Bool { !allRunIds.contains { $0.count < id.count && id.hasPrefix($0) } }
        let cleanRunIds = allRunIds.filter(isCanonicalRun)

        // ---- totals (assigned incrementally: one big [String:Any] literal blows the type-checker) ----
        let chars = saidUtter.reduce(0) { $0 + $1.str("said").count }
        var totals: [String: Any] = [:]
        totals["events"] = evs.count
        totals["utterances"] = utter.count
        totals["chars"] = chars
        totals["agents"] = Set(evs.compactMap { $0.sessionKey }).count
        totals["machines"] = Set(evs.compactMap { $0.strOrNil("machine") }).count
        totals["sessionsNew"] = k("sessionNew").count
        totals["sessionsKilled"] = k("sessionKill").count
        totals["wandbRuns"] = cleanRunIds.count
        totals["gitPanels"] = k("gitPanel").count
        totals["gitInsights"] = k("gitInsight").count
        totals["workflows"] = k("workflowRun").count
        totals["todos"] = k("todo").count
        totals["fileSaves"] = k("fileSave").count
        totals["redacted"] = utter.filter { $0.bool("redacted") }.count
        totals["phoneMsgs"] = utter.filter { $0.str("src") == "phone" }.count
        totals["corrections"] = k("manualStatus").count
        totals["outcomes"] = k("outcome").count
        totals["viewedMinutes"] = Int(k("viewed").reduce(0.0) { $0 + $1.dbl("dwellSec") } / 60)
        out["totals"] = totals

        // ---- hour histogram (local) + night owl ----
        var hours = [Int](repeating: 0, count: 24)
        for e in evs { if let h = e.localHour { hours[h] += 1 } }
        out["hourHistogram"] = hours
        let peakHour = hours.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let nightCount = (0..<6).reduce(0) { $0 + hours[$1] } + hours[23]
        out["rhythm"] = ["peakHour": peakHour, "nightScore": Int(100.0 * Double(nightCount) / Double(max(1, evs.count)))]

        // ---- status mix: how the fleet spent its collective time (working / waiting on you / stuck / idle …) ----
        var statusMix: [String: Int] = [:]
        for e in k("status") { statusMix[e.str("to"), default: 0] += 1 }
        out["statusMix"] = statusMix

        // ---- day-of-week (0=Sun) ----
        var dow = [Int](repeating: 0, count: 7)
        for e in evs { if let d = e.date { dow[(cal.component(.weekday, from: d) - 1) % 7] += 1 } }
        out["dow"] = dow

        // ---- heatmap: per active day × 24 hours ----
        var byDayHour: [String: [Int]] = [:]
        for e in evs {
            guard let day = e.localDay, let h = e.localHour else { continue }
            byDayHour[day, default: [Int](repeating: 0, count: 24)][h] += 1
        }
        out["heatmap"] = byDayHour.keys.sorted().map { ["day": $0, "hours": byDayHour[$0]!] }

        // ---- pulse: adaptive buckets (≈120 points max) with top session per bucket ----
        out["pulse"] = pulse(evs, first: first, last: last)

        // ---- fleet over time (alive agents) ----
        out["fleet"] = fleetOverTime(evs)

        // ---- agents leaderboard ----
        var agents: [String: (session: String, machine: String, msgs: Int, firstT: Date, lastT: Date)] = [:]
        for e in utter {
            guard let key = e.sessionKey, let d = e.date else { continue }
            if var a = agents[key] { a.msgs += 1; a.firstT = min(a.firstT, d); a.lastT = max(a.lastT, d); agents[key] = a }
            else { agents[key] = (e.str("session"), e.str("machine"), 1, d, d) }
        }
        out["agents"] = agents.values.sorted { $0.msgs > $1.msgs }.prefix(24).map {
            ["session": $0.session, "machine": $0.machine, "messages": $0.msgs,
             "lifespanSec": Int($0.lastT.timeIntervalSince($0.firstT))]
        }

        // ---- machines ----
        var mach: [String: (events: Int, sessions: Set<String>)] = [:]
        for e in evs {
            guard let m = e.strOrNil("machine") else { continue }
            var v = mach[m] ?? (0, [])
            v.events += 1
            if let s = e.sessionKey { v.sessions.insert(s) }
            mach[m] = v
        }
        out["machines"] = mach.map { ["name": $0.key, "events": $0.value.events, "sessions": $0.value.sessions.count] }
            .sorted { ($0["events"] as! Int) > ($1["events"] as! Int) }

        // ---- top words / catchphrase ----
        var firstWords: [String: Int] = [:]
        for e in saidUtter {
            let w = e.str("said").split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map { String($0).lowercased() } ?? ""
            let clean = w.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "!/")))
            if !clean.isEmpty { firstWords[clean, default: 0] += 1 }
        }
        let topWords = firstWords.sorted { $0.value > $1.value }.prefix(15).map { ["word": $0.key, "count": $0.value] }
        out["topWords"] = topWords
        if let cw = topWords.first { out["catchphrase"] = cw }

        // ---- sentiment over buckets ----
        out["sentiment"] = sentiment(saidUtter, first: first, last: last)

        // ---- message length histogram ----
        let buckets = [(0, 20, "≤20"), (20, 50, "20–50"), (50, 100, "50–100"), (100, 200, "100–200"), (200, 500, "200–500"), (500, .max, "500+")]
        out["lengthHistogram"] = buckets.map { lo, hi, label in
            ["label": label, "count": saidUtter.filter { let c = $0.str("said").count; return c >= lo && c < hi }.count]
        }

        // ---- projects (by folder basename) ----
        var proj: [String: (events: Int, sessions: Set<String>)] = [:]
        for e in evs {
            let f = e.strOrNil("folder") ?? ""
            guard !f.isEmpty, f != "—" else { continue }
            let base = (f as NSString).lastPathComponent
            var v = proj[base] ?? (0, [])
            v.events += 1
            if let s = e.sessionKey { v.sessions.insert(s) }
            proj[base] = v
        }
        out["projects"] = proj.map { ["name": $0.key, "events": $0.value.events, "sessions": $0.value.sessions.count] }
            .sorted { ($0["events"] as! Int) > ($1["events"] as! Int) }.prefix(12).map { $0 }

        // ---- streak ----
        out["streak"] = streak(activeDays)

        // ---- superlatives ----
        out["superlatives"] = superlatives(evs: evs, saidUtter: saidUtter, cal: cal)

        // ---- delegation ratio ----
        out["delegation"] = delegation(evs: evs, saidUtter: saidUtter)

        // ---- experiments / questions / todos / shipped ----
        var seenRun = Set<String>()
        out["experiments"] = k("wandbRun").compactMap { e -> [String: Any]? in
            guard let r = e.strOrNil("runId"), isCanonicalRun(r), !seenRun.contains(r) else { return nil }
            seenRun.insert(r)
            // project = the path segment right before "/runs/" in the W&B url
            let parts = e.str("url").components(separatedBy: "/")
            let proj = parts.firstIndex(of: "runs").flatMap { $0 > 0 ? parts[$0 - 1] : nil } ?? ""
            return ["session": e.str("session"), "url": e.str("url"), "runId": r, "project": proj]
        }
        out["questions"] = k("gitInsight").compactMap { $0.strOrNil("question") }
        out["todos"] = k("todo").map { ["action": $0.str("action"), "text": $0.str("text"), "board": $0.str("board")] }
        // shipped: the milestones the fleet actually reported (status → milestone/completed),
        // most recent first, deduped, at most 2 per agent so one chatty session can't dominate.
        var seenSum = Set<String>()
        var perSessShip: [String: Int] = [:]
        var shipped: [[String: Any]] = []
        let milestones = k("status")
            .filter { $0.str("to") == "milestone" || $0.str("to") == "completed" }
            .compactMap { e -> (Date, String, String)? in
                let s = e.str("summary").trimmingCharacters(in: .whitespacesAndNewlines)
                guard s.count > 24, let d = e.date else { return nil }
                return (d, e.str("session"), s)
            }
            .sorted { $0.0 > $1.0 }
        for (_, sess, summary) in milestones {
            if seenSum.contains(summary) || perSessShip[sess, default: 0] >= 2 { continue }
            seenSum.insert(summary); perSessShip[sess, default: 0] += 1
            shipped.append(["session": sess, "text": summary])
            if shipped.count >= 12 { break }
        }
        out["shipped"] = shipped

        // ---- awards + archetype ----
        out["awards"] = awards(out)
        out["archetype"] = archetype(out)

        return out
    }

    // MARK: derivations

    private static func pulse(_ evs: [Event], first: Date, last: Date) -> [[String: Any]] {
        let span = max(1, last.timeIntervalSince(first))
        let bucketCount = 120
        let bucketSec = span / Double(bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount + 1)
        var sessByBucket = [[String: Int]](repeating: [:], count: bucketCount + 1)
        for e in evs {
            guard let d = e.date else { continue }
            let idx = min(bucketCount, Int(d.timeIntervalSince(first) / bucketSec))
            counts[idx] += 1
            if let s = e.strOrNil("session") { sessByBucket[idx][s, default: 0] += 1 }
        }
        return counts.enumerated().map { i, c in
            let top = sessByBucket[i].max(by: { $0.value < $1.value })?.key ?? ""
            let t = first.addingTimeInterval(Double(i) * bucketSec)
            return ["t": t.timeIntervalSince1970, "count": c, "top": top]
        }
    }

    private static func fleetOverTime(_ evs: [Event]) -> [[String: Any]] {
        // +1 on sessionNew, -1 on sessionKill, in time order → running alive count.
        let markers = evs.filter { $0.kind == "sessionNew" || $0.kind == "sessionKill" }
            .compactMap { e -> (Date, Int)? in e.date.map { ($0, e.kind == "sessionNew" ? 1 : -1) } }
            .sorted { $0.0 < $1.0 }
        var alive = 0
        var series: [[String: Any]] = []
        for (d, delta) in markers {
            alive = max(0, alive + delta)
            series.append(["t": d.timeIntervalSince1970, "alive": alive])
        }
        let peak = series.map { $0["alive"] as! Int }.max() ?? 0
        return series.isEmpty ? [] : ([["peak": peak]] + series)
    }

    private static let posWords: Set<String> = ["cool", "cool!", "nice", "great", "perfect", "awesome", "works", "yes", "good", "thanks", "love", "amazing", "beautiful", "ship"]
    private static let negWords: Set<String> = ["no", "wait", "stop", "why", "wrong", "broken", "fuck", "shit", "damn", "ugh", "bug", "fail", "failed", "buggy", "dude", "still", "not"]

    private static func sentiment(_ utter: [Event], first: Date, last: Date) -> [[String: Any]] {
        let span = max(1, last.timeIntervalSince(first))
        let n = 60
        let bs = span / Double(n)
        var pos = [Int](repeating: 0, count: n + 1), neg = [Int](repeating: 0, count: n + 1)
        for e in utter {
            guard let d = e.date else { continue }
            let idx = min(n, Int(d.timeIntervalSince(first) / bs))
            let words = Set(e.str("said").lowercased().split(whereSeparator: { !$0.isLetter && $0 != "!" }).map(String.init))
            pos[idx] += words.intersection(posWords).count
            neg[idx] += words.intersection(negWords).count
        }
        return (0...n).map { i in ["t": first.addingTimeInterval(Double(i) * bs).timeIntervalSince1970, "pos": pos[i], "neg": neg[i]] }
    }

    private static func streak(_ activeDays: Set<String>) -> [String: Any] {
        let sorted = activeDays.sorted()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var longest = 0, cur = 0
        var prev: Date?
        for s in sorted {
            guard let d = f.date(from: s) else { continue }
            if let p = prev, Calendar.current.dateComponents([.day], from: p, to: d).day == 1 { cur += 1 } else { cur = 1 }
            longest = max(longest, cur); prev = d
        }
        return ["activeDays": sorted, "longest": longest]
    }

    private static func superlatives(evs: [Event], saidUtter: [Event], cal: Calendar) -> [String: Any] {
        var out: [String: Any] = [:]
        if let lm = saidUtter.max(by: { $0.str("said").count < $1.str("said").count }) {
            out["longestMessage"] = ["chars": lm.str("said").count]
        }
        // fastest kill
        var born: [String: Date] = [:]
        var fastest: (String, Double)?
        for e in evs.sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            guard let key = e.sessionKey, let d = e.date else { continue }
            if e.kind == "sessionNew" { born[key] = d }
            else if e.kind == "sessionKill", let b = born[key] {
                let life = d.timeIntervalSince(b)
                if fastest == nil || life < fastest!.1 { fastest = (e.str("session"), life) }
            }
        }
        if let f = fastest { out["fastestKill"] = ["session": f.0, "sec": Int(f.1)] }
        // busiest minute
        var perMin: [String: Int] = [:]
        let mf = DateFormatter(); mf.dateFormat = "yyyy-MM-dd HH:mm"; mf.timeZone = .current
        for e in saidUtter { if let d = e.date { perMin[mf.string(from: d), default: 0] += 1 } }
        if let bm = perMin.max(by: { $0.value < $1.value }) { out["busiestMinute"] = ["minute": bm.key, "count": bm.value] }
        // longest silence
        let ut = saidUtter.compactMap { $0.date }.sorted()
        var maxGap = 0.0
        for i in 1..<max(1, ut.count) { maxGap = max(maxGap, ut[i].timeIntervalSince(ut[i - 1])) }
        out["longestSilenceHours"] = Double(round(10 * maxGap / 3600) / 10)
        // busiest day
        var perDay: [String: Int] = [:]
        for e in evs { if let d = e.localDay { perDay[d, default: 0] += 1 } }
        if let bd = perDay.max(by: { $0.value < $1.value }) { out["busiestDay"] = ["day": bd.key, "count": bd.value] }
        // most rounds with one agent in a day
        var perSessDay: [String: Int] = [:]
        for e in saidUtter { if let d = e.localDay, let s = e.strOrNil("session") { perSessDay["\(s)|\(d)", default: 0] += 1 } }
        if let mr = perSessDay.max(by: { $0.value < $1.value }) {
            let parts = mr.key.split(separator: "|", maxSplits: 1).map(String.init)
            out["mostRounds"] = ["session": parts.first ?? "", "day": parts.count > 1 ? parts[1] : "", "count": mr.value]
        }
        return out
    }

    private static func delegation(evs: [Event], saidUtter: [Event]) -> [String: Any] {
        // agent working time: sum spans a session sits in "working" (from status transitions).
        var lastWorkingStart: [String: Date] = [:]
        var workingSec = 0.0
        for e in evs.filter({ $0.kind == "status" }).sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            guard let s = e.strOrNil("session"), let d = e.date else { continue }
            let to = e.str("to")
            if to == "working", lastWorkingStart[s] == nil { lastWorkingStart[s] = d }
            else if to != "working", let start = lastWorkingStart[s] {
                workingSec += min(3600, d.timeIntervalSince(start)) // cap a single span at 1h so a stuck state can't dominate
                lastWorkingStart[s] = nil
            }
        }
        // your active minutes: distinct minutes with an utterance.
        let mf = DateFormatter(); mf.dateFormat = "yyyy-MM-dd HH:mm"; mf.timeZone = .current
        let activeMin = Set(saidUtter.compactMap { $0.date.map { mf.string(from: $0) } }).count
        let ratio = activeMin > 0 ? (workingSec / 60.0) / Double(activeMin) : 0
        return ["agentWorkingMin": Int(workingSec / 60), "activeMin": activeMin, "ratio": Double(round(10 * ratio) / 10)]
    }

    /// Earned badges — each carries its own icon and the real number that unlocked it,
    /// so a badge reads as specific ("50 agents commanded"), not a generic star.
    private static func awards(_ out: [String: Any]) -> [[String: String]] {
        var a: [[String: String]] = []
        let t = out["totals"] as? [String: Any] ?? [:]
        let r = out["rhythm"] as? [String: Any] ?? [:]
        func i(_ d: [String: Any], _ k: String) -> Int { (d[k] as? Int) ?? 0 }
        func add(_ icon: String, _ name: String, _ detail: String) { a.append(["icon": icon, "name": name, "detail": detail]) }
        if i(t, "agents") >= 20 { add("⚓️", "Fleet Admiral", "\(i(t, "agents")) agents commanded") }
        if i(t, "machines") >= 5 { add("🖥️", "Fleet Commander", "across \(i(t, "machines")) machines") }
        if i(r, "nightScore") >= 30 { add("🦉", "Night Owl", "\(i(r, "nightScore"))% of activity after midnight") }
        if i(t, "phoneMsgs") > 0 { add("📱", "Phone Warrior", "\(i(t, "phoneMsgs")) messages sent from your phone") }
        if i(t, "chars") >= 100_000 { add("✍️", "Novelist", "≈\(i(t, "chars") / 1800) pages typed to agents") }
        if i(t, "redacted") >= 50 { add("🔒", "Vault Keeper", "\(i(t, "redacted")) secrets auto-redacted") }
        if i(t, "wandbRuns") >= 5 { add("🧪", "Experimentalist", "\(i(t, "wandbRuns")) experiments launched") }
        if i(t, "gitPanels") >= 20 { add("🔍", "Code Reviewer", "\(i(t, "gitPanels")) diffs opened") }
        if let s = out["streak"] as? [String: Any], let lg = s["longest"] as? Int, lg >= 3 { add("🔥", "On a Roll", "\(lg)-day active streak") }
        if let d = out["delegation"] as? [String: Any], let ratio = d["ratio"] as? Double, ratio >= 3 { add("🎯", "The Delegator", "agents worked \(Int(ratio))× your active time") }
        return a
    }

    private static func archetype(_ out: [String: Any]) -> [String: String] {
        let t = out["totals"] as? [String: Any] ?? [:]
        let r = out["rhythm"] as? [String: Any] ?? [:]
        let night = (r["nightScore"] as? Int) ?? 0
        let machines = (t["machines"] as? Int) ?? 0
        let ratio = (out["delegation"] as? [String: Any])?["ratio"] as? Double ?? 0
        if night >= 35 { return ["name": "The Nocturnal Commander", "blurb": "You run your fleet while the world sleeps."] }
        if ratio >= 4 { return ["name": "The Delegator", "blurb": "You point; your agents do. Leverage is your love language."] }
        if machines >= 6 { return ["name": "The Fleet Admiral", "blurb": "Your reach spans laptops, clusters, and the cloud."] }
        return ["name": "The Orchestrator", "blurb": "One mind, many machines, one baton."]
    }

    // MARK: journal loading

    static func loadEvents() -> [Event] {
        let dir = ActivityJournal.dirURL
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [Event] = []
        for url in files where url.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let d = String(line).data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                out.append(Event(obj))
            }
        }
        return out
    }

    /// One journal event with typed accessors + cached local-time fields.
    struct Event {
        let raw: [String: Any]
        let kind: String
        let date: Date?
        init(_ raw: [String: Any]) {
            self.raw = raw
            self.kind = (raw["kind"] as? String) ?? "?"
            self.date = Self.parse(raw["ts"] as? String ?? "")
        }
        func str(_ k: String) -> String { (raw[k] as? String) ?? "" }
        func strOrNil(_ k: String) -> String? { let s = raw[k] as? String; return (s?.isEmpty ?? true) ? nil : s }
        func bool(_ k: String) -> Bool { (raw[k] as? Bool) ?? false }
        func dbl(_ k: String) -> Double { (raw[k] as? Double) ?? Double((raw[k] as? Int) ?? 0) }
        var sessionKey: String? {
            guard let s = strOrNil("session") else { return nil }
            return (strOrNil("machineID") ?? "?") + "|" + s
        }
        var localHour: Int? { date.map { Calendar.current.component(.hour, from: $0) } }
        var localDay: String? { date.map { WrappedStats.localDayString($0) } }
        private static let iso1: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f }()
        private static let iso2: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f }()
        static func parse(_ s: String) -> Date? { iso1.date(from: s) ?? iso2.date(from: s) }
    }

    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f }()
    static func localDayString(_ d: Date) -> String { dayFmt.string(from: d) }
}
