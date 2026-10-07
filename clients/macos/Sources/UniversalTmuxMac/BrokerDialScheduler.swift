import Foundation

/// A fair, bounded queue with foreground priority and reserved foreground
/// capacity. Only attempts (not established sockets) occupy slots.
final class BrokerDialScheduler {
    static let shared = BrokerDialScheduler()
    private struct Entry {
        let id: UUID
        let host: String
        var foreground: Bool
        let grant: () -> Void
        let revoke: () -> Void
    }
    private let lock = NSLock()
    private var waiting: [Entry] = []
    private var active: [UUID: Entry] = [:]
    private let capacity: Int
    init(capacity: Int = 3) { self.capacity = max(1, capacity) }

    func request(id: UUID, host: String, foreground: Bool, grant: @escaping () -> Void, revoke: @escaping () -> Void) {
        change {
            waiting.append(Entry(id: id, host: host, foreground: foreground, grant: grant, revoke: revoke))
        }
    }
    func release(_ id: UUID) {
        change { active[id] = nil; waiting.removeAll { $0.id == id } }
    }
    func prioritize(_ id: UUID, foreground: Bool) {
        change {
            if let i = waiting.firstIndex(where: { $0.id == id }) { waiting[i].foreground = foreground }
            active[id]?.foreground = foreground
        }
    }
    private func change(_ mutation: () -> Void) {
        lock.lock()
        mutation()
        var callbacks: [() -> Void] = []
        for host in Set(waiting.map(\.host)) {
            // A previously foreground attempt may have become hidden while
            // connecting. Yield it when necessary, instead of starving a click.
            if waiting.contains(where: { $0.host == host && $0.foreground }),
               active.values.filter({ $0.host == host }).count >= capacity,
               let victim = active.values.first(where: { $0.host == host && !$0.foreground }) {
                active[victim.id] = nil
                waiting.append(victim)
                callbacks.append(victim.revoke)
            }
            while active.values.filter({ $0.host == host }).count < capacity {
                let foreground = waiting.firstIndex { $0.host == host && $0.foreground }
                let backgrounds = active.values.filter { $0.host == host && !$0.foreground }.count
                let background = backgrounds < max(1, capacity - 1)
                    ? waiting.firstIndex { $0.host == host && !$0.foreground } : nil
                guard let index = foreground ?? background else { break }
                let entry = waiting.remove(at: index)
                active[entry.id] = entry
                callbacks.append(entry.grant)
            }
        }
        lock.unlock()
        // Never invoke client code while holding scheduler state.
        callbacks.forEach { callback in DispatchQueue.main.async(execute: callback) }
    }
}

struct BrokerRecoveryConfiguration {
    var handshakeTimeout: TimeInterval = 20
    var firstFrameTimeout: TimeInterval = 10
    var heartbeatInterval: TimeInterval = 20
    var heartbeatTimeout: TimeInterval = 10
}
