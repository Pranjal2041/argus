import Foundation

enum BrokerConnectionStatus: String {
    case checking, reachable, delayed, unreachable

    var permitsInteraction: Bool { self != .unreachable }
}

enum BrokerRefreshFailure: Equatable {
    case transport(Int), http(Int), invalidSnapshot, invalidURL

    var detail: String {
        switch self {
        case .transport(let code): return "Session refresh failed (network error \(code)). Retrying automatically."
        case .http(let code): return "The broker responded with HTTP \(code). Retrying the session refresh."
        case .invalidSnapshot: return "The broker responded, but its session list could not be decoded."
        case .invalidURL: return "The broker address is invalid."
        }
    }

    var isTransportFailure: Bool {
        if case .transport = self { return true }
        return false
    }
}

enum BrokerSnapshotResult {
    case success([SessionInfo])
    case failure(BrokerRefreshFailure)
}

/// One common health policy for every broker route. A timeout is an observation
/// about one operation, not proof that the machine is offline. Use monotonic time
/// so clock corrections cannot prolong or prematurely expire reachability.
struct BrokerHealth {
    static let evidenceLifetime: TimeInterval = 30
    private(set) var status: BrokerConnectionStatus = .checking
    private(set) var failureCount = 0
    private var firstFailureAt: TimeInterval?
    private(set) var lastReachableAt: TimeInterval?

    mutating func observe(_ evidence: TimeInterval?, now: TimeInterval) -> Bool {
        guard let evidence, now - evidence < Self.evidenceLifetime else { return false }
        lastReachableAt = max(lastReachableAt ?? evidence, evidence)
        if status == .unreachable { status = .delayed; return true }
        return false
    }

    mutating func record(success: Bool, responding: Bool, evidence: TimeInterval?, now: TimeInterval,
                         offlineEligible: Bool = true) {
        if let evidence { lastReachableAt = max(lastReachableAt ?? evidence, evidence) }
        if success || responding { lastReachableAt = now }
        if success {
            failureCount = 0
            firstFailureAt = nil
            status = .reachable
            return
        }
        failureCount += 1
        if firstFailureAt == nil { firstFailureAt = now }
        let lastEvidence = max(firstFailureAt ?? now, lastReachableAt ?? 0)
        status = offlineEligible && failureCount >= 3 && now - lastEvidence >= Self.evidenceLifetime
            ? .unreachable : .delayed
    }

    var retryDelay: TimeInterval {
        failureCount == 0 ? 0 : min(30, pow(2, Double(min(failureCount, 5))))
    }

    mutating func resetRetryBudget() {
        failureCount = 0
        firstFailureAt = nil
    }
}

/// Positive, expiring evidence only: an idle socket's `connected` flag is not a
/// heartbeat. Any received WebSocket frame proves the route was live at that
/// instant. The registry is bounded, carries no payloads, and never changes UI
/// state on the terminal's hot output path.
final class BrokerReachabilityEvidence {
    static let shared = BrokerReachabilityEvidence()
    private let lock = NSLock()
    private var observed: [String: TimeInterval] = [:]

    private func origin(_ url: URL) -> String? {
        guard let host = url.host else { return nil }
        let secure = url.scheme == "https" || url.scheme == "wss"
        return "\(secure ? "https" : "http")://\(host.lowercased()):\(url.port ?? (secure ? 443 : 80))"
    }

    func record(url: URL, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let key = origin(url) else { return }
        lock.lock(); defer { lock.unlock() }
        observed[key] = now
        if observed.count > 256 {
            observed = observed.filter { now - $0.value < BrokerHealth.evidenceLifetime }
            if observed.count > 256, let oldest = observed.min(by: { $0.value < $1.value })?.key {
                observed.removeValue(forKey: oldest)
            }
        }
    }

    func latest(httpBase: String) -> TimeInterval? {
        guard let url = URL(string: httpBase), let key = origin(url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return observed[key]
    }
}

struct BrokerSessionUpdate {
    let scope: SessionRefreshScope
    let sessions: [SessionInfo]?
    let status: BrokerConnectionStatus
    let issue: String?
    let roundTripMilliseconds: Int
}

/// Single-flight, bounded polling shared by timer, selection, and manual refresh.
/// Full refresh requests coalesce into at most one follow-up; route replacement
/// cancels and retires the old generation before any callback can publish.
@MainActor
final class BrokerSessionMonitor {
    typealias Fetch = (Machine, SessionRefreshScope) async -> BrokerSnapshotResult
    typealias Probe = (Machine) async -> Bool

    private final class Entry {
        let machine: Machine
        var task: Task<Void, Never>?
        var scope: SessionRefreshScope = .foreground
        var wantsFull = false
        var completions: [() -> Void] = []
        var fullCompletions: [() -> Void] = []
        var health = BrokerHealth()
        var issue: String?
        var nextPoll: TimeInterval = 0
        init(_ machine: Machine) { self.machine = machine }
    }

    private var entries: [String: Entry] = [:]
    private let fetch: Fetch
    private let probe: Probe
    private let now: () -> TimeInterval
    private let evidence: (String) -> TimeInterval?
    var onUpdate: ((Machine, BrokerSessionUpdate) -> Void)?

    init(
        fetch: @escaping Fetch = BrokerSessionMonitor.fetchSnapshot,
        probe: @escaping Probe = BrokerSessionMonitor.probeBroker,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        evidence: @escaping (String) -> TimeInterval? = { BrokerReachabilityEvidence.shared.latest(httpBase: $0) }
    ) {
        self.fetch = fetch
        self.probe = probe
        self.now = now
        self.evidence = evidence
    }

    func refresh(_ machine: Machine, scope: SessionRefreshScope, force: Bool = false, completion: (() -> Void)? = nil) {
        if let old = entries[machine.id], old.machine.httpBase != machine.httpBase {
            retire(machine.id)
        }
        let entry = entries[machine.id] ?? Entry(machine)
        entries[machine.id] = entry
        if entry.health.observe(evidence(machine.httpBase), now: now()) {
            entry.nextPoll = 0 // fresh terminal traffic also ends the offline retry backoff
            onUpdate?(machine, BrokerSessionUpdate(scope: scope, sessions: nil,
                status: .delayed, issue: entry.issue, roundTripMilliseconds: 0))
        }
        if entry.task != nil {
            if scope == .all && entry.scope == .foreground {
                entry.wantsFull = true
                if let completion { entry.fullCompletions.append(completion) }
            } else if let completion { entry.completions.append(completion) }
            return
        }
        guard force || now() >= entry.nextPoll else {
            if scope == .all { entry.wantsFull = true }
            completion?()
            return
        }
        if let completion { entry.completions.append(completion) }
        start(entry, scope: entry.wantsFull ? .all : scope)
    }

    func retainMachines(_ machines: [Machine]) {
        let routes = Dictionary(machines.map { ($0.id, $0.httpBase) }, uniquingKeysWith: { _, new in new })
        let retired = entries.filter { routes[$0.key] != $0.value.machine.httpBase }.map(\.key)
        retired.forEach { retire($0) }
    }

    func networkRecovered() {
        for entry in entries.values {
            let needsRetry = entry.task != nil || entry.health.failureCount > 0
            entry.task?.cancel(); entry.task = nil
            entry.nextPoll = 0
            entry.health.resetRetryBudget()
            if needsRetry {
                let scope: SessionRefreshScope = entry.wantsFull ? .all : entry.scope
                if scope == .all {
                    entry.completions += entry.fullCompletions
                    entry.fullCompletions.removeAll()
                }
                start(entry, scope: scope)
            }
        }
    }

    private func retire(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.task?.cancel()
        entry.completions.forEach { $0() }
        entry.fullCompletions.forEach { $0() }
    }

    private func start(_ entry: Entry, scope: SessionRefreshScope) {
        entry.scope = scope
        if scope == .all { entry.wantsFull = false }
        let machine = entry.machine
        let started = now()
        let fetch = self.fetch, probe = self.probe
        entry.task = Task { [weak self, weak entry] in
            let result = await fetch(machine, scope)
            guard !Task.isCancelled, let self, let entry, self.entries[machine.id] === entry else { return }
            let roundTrip = Int((self.now() - started) * 1_000)
            var responding = false
            var sessions: [SessionInfo]?
            var failure: BrokerRefreshFailure?
            switch result {
            case .success(let snapshot): sessions = snapshot
            case .failure(let issue):
                failure = issue
                if issue.isTransportFailure {
                    // A short independent endpoint distinguishes a slow session
                    // enumeration from a dead broker. Fresh terminal traffic is
                    // already sufficient evidence; don't add needless probes.
                    let recent = self.evidence(machine.httpBase).map {
                        self.now() - $0 < BrokerHealth.evidenceLifetime
                    } ?? false
                    if !recent { responding = await probe(machine) }
                } else if issue != .invalidURL {
                    responding = true // HTTP/schema failures are not an offline machine.
                }
            }
            guard !Task.isCancelled, self.entries[machine.id] === entry else { return }
            let oldStatus = entry.health.status
            entry.health.record(success: sessions != nil, responding: responding,
                                evidence: self.evidence(machine.httpBase), now: self.now(),
                                offlineEligible: failure?.isTransportFailure == true)
            entry.nextPoll = self.now() + entry.health.retryDelay
            entry.issue = failure?.detail
            let update = BrokerSessionUpdate(scope: scope, sessions: sessions,
                status: entry.health.status, issue: failure?.detail, roundTripMilliseconds: roundTrip)
            // No response bodies, credentials, query strings, or workspace paths.
            if failure != nil || oldStatus != entry.health.status {
                TerminalConnectionTrace.record("broker.session_refresh", [
                    "machine": machine.id, "host": URL(string: machine.httpBase)?.host ?? "invalid",
                    "scope": scope == .all ? "all" : "foreground",
                    "status": entry.health.status.rawValue, "failure": failure?.detail ?? "",
                    "durationMs": roundTrip, "failures": entry.health.failureCount,
                    "probeResponded": responding,
                ])
            }
            entry.task = nil
            let completions = entry.completions
            entry.completions.removeAll()
            if entry.wantsFull {
                // At most one queued full snapshot, even after repeated manual
                // refresh clicks. A failed poll retains the intent until backoff
                // expires, unless a manual caller is explicitly waiting on it.
                if sessions != nil || !entry.fullCompletions.isEmpty {
                    entry.completions = entry.fullCompletions
                    entry.fullCompletions.removeAll()
                    self.start(entry, scope: .all)
                }
            }
            // Install any follow-up BEFORE calling client code, which can
            // synchronously request another refresh or retire this route.
            self.onUpdate?(machine, update)
            completions.forEach { $0() }
        }
    }

    deinit { entries.values.forEach { $0.task?.cancel() } }

    nonisolated static func fetchSnapshot(_ machine: Machine, _ scope: SessionRefreshScope) async -> BrokerSnapshotResult {
        await fetchSnapshot(machine, scope, session: brokerMonitoringSession)
    }

    nonisolated static func fetchSnapshot(_ machine: Machine, _ scope: SessionRefreshScope, session: URLSession) async -> BrokerSnapshotResult {
        var components = URLComponents(string: machine.httpBase + "/sessions")
        if scope == .foreground { components?.queryItems = [URLQueryItem(name: "scope", value: "foreground")] }
        guard let url = components?.url else { return .failure(.invalidURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport(URLError.badServerResponse.rawValue)) }
            guard (200..<300).contains(http.statusCode) else { return .failure(.http(http.statusCode)) }
            guard let decoded = try? JSONDecoder().decode(SessionsResponse.self, from: data) else {
                return .failure(.invalidSnapshot)
            }
            return .success(decoded.sessions)
        } catch { return .failure(.transport((error as NSError).code)) }
    }

    nonisolated static func probeBroker(_ machine: Machine) async -> Bool {
        guard let url = URL(string: machine.httpBase + "/whoami") else { return false }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        guard let (_, response) = try? await brokerMonitoringSession.data(for: request) else { return false }
        return response is HTTPURLResponse
    }
}
