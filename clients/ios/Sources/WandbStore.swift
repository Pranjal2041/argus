import Foundation

/// Per-session W&B runs found in terminal output (detector shared with macOS),
/// kept for 7 days like the Android and macOS clients.
enum WandbStore {
    private static let key = "argus.wandbRuns.v1"
    private static let ttl: TimeInterval = 7 * 24 * 3600

    static func runs(key session: String) -> [WandbRun] {
        let fresh = (load()[session] ?? []).filter { Date().timeIntervalSince($0.discoveredAt) < ttl }
        return fresh.sorted { $0.discoveredAt > $1.discoveredAt }
    }

    /// Union by run id, keeping the first-seen time and a real name over a bare id.
    static func merge(_ found: [WandbRun], key session: String) -> [WandbRun] {
        var all = load()
        var byId = Dictionary((all[session] ?? []).map { ($0.runId, $0) }, uniquingKeysWith: { a, _ in a })
        for r in found {
            if var old = byId[r.runId] {
                if old.label == old.runId || r.label != r.runId {
                    old = WandbRun(url: r.url, runId: r.runId, label: r.label == r.runId ? old.label : r.label,
                                   discoveredAt: old.discoveredAt)
                }
                byId[r.runId] = old
            } else {
                byId[r.runId] = r
            }
        }
        all[session] = Array(byId.values)
        save(all)
        return runs(key: session)
    }

    private static func load() -> [String: [WandbRun]] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([String: [WandbRun]].self, from: d) else { return [:] }
        return v
    }
    private static func save(_ v: [String: [WandbRun]]) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }
}
