import Foundation

/// Admission is ordered before transport starts, not by which machine answers
/// first. A session has at most one active job and one coalesced follow-up.
/// Finishing a job makes capacity available immediately, independently of the
/// cadence used to discover new work.
struct SessionSummaryQueue<Work> {
    struct Entry {
        let key: String
        var work: Work
    }

    let capacity: Int
    private(set) var active: Set<String> = []
    private var order: [String] = []
    private var pending: [String: Work] = [:]
    var pendingKeys: Set<String> { Set(pending.keys) }

    init(capacity: Int = 5) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func enqueue(_ key: String, work: Work, merge: (Work, Work) -> Work) {
        if let previous = pending[key] { pending[key] = merge(previous, work) }
        else { order.append(key); pending[key] = work }
    }

    mutating func next(where eligible: (String, Work) -> Bool = { _, _ in true }) -> Entry? {
        guard active.count < capacity,
              let index = order.firstIndex(where: { key in
                  !active.contains(key) && pending[key].map { eligible(key, $0) } == true
              }) else { return nil }
        let key = order.remove(at: index)
        guard let work = pending.removeValue(forKey: key) else { return nil }
        active.insert(key)
        return Entry(key: key, work: work)
    }

    mutating func finish(_ key: String) { active.remove(key) }

    mutating func retainPending(where keep: (String, Work) -> Bool) {
        pending = pending.filter { keep($0.key, $0.value) }
        order.removeAll { pending[$0] == nil }
    }

    mutating func removeAllPending() { order.removeAll(); pending.removeAll() }
}
