import Foundation

enum Op {
    static let output: UInt8 = 1
    static let input: UInt8 = 2
    static let resize: UInt8 = 3
    static let requestSnapshot: UInt8 = 4 // ask the broker for a fresh authoritative redraw
    static let paneSize: UInt8 = 5 // broker → us: the pane's AUTHORITATIVE cols×rows.
    static let snapshotBegin: UInt8 = 6
    static let snapshotEnd: UInt8 = 7
    // %output bytes are formatted for exactly this grid; rendering at any other
    // width shears the screen, so the terminal pins to it (opResize is only an ask).
}

/// Live state of a broker socket, surfaced to the UI (header status chip).
enum ConnState: Equatable {
    case connecting, connected, reconnecting, suspended, closed
}

/// Client-to-broker input framing. The broker protocol has no logical-message
/// size field, so a large terminal paste is represented by several ordinary
/// input frames. Four KiB is intentionally below both coder/websocket's legacy
/// 32 KiB read limit and tmux's roughly 10,000-argument `send-keys -H` parser
/// ceiling, which also makes a new app safe against brokers not yet upgraded.
enum BrokerWireFrames {
    static let maxInputPayloadBytes = 4 * 1024

    static func encode(op: UInt8, pane: String, payload: [UInt8]) -> [Data] {
        let paneBytes = Array(pane.utf8)
        guard paneBytes.count <= Int(UInt8.max) else { return [] }

        let chunkSize = op == Op.input ? maxInputPayloadBytes : max(1, payload.count)
        if payload.isEmpty {
            return [frame(op: op, pane: paneBytes, payload: payload[...])]
        }

        var frames: [Data] = []
        frames.reserveCapacity((payload.count + chunkSize - 1) / chunkSize)
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            frames.append(frame(op: op, pane: paneBytes, payload: payload[offset..<end]))
            offset = end
        }
        return frames
    }

    private static func frame(
        op: UInt8,
        pane: [UInt8],
        payload: ArraySlice<UInt8>
    ) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(2 + pane.count + payload.count)
        bytes.append(op)
        bytes.append(UInt8(pane.count))
        bytes.append(contentsOf: pane)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }
}

/// Serializes asynchronous WebSocket writes explicitly. SwiftTerm emits a
/// bracketed paste as start marker, content, end marker; allowing multiple
/// URLSession sends to race can reorder those pieces. This queue sends exactly
/// one frame at a time and drops stale work when a socket generation retires —
/// input is never replayed into a new connection after a disconnect.
final class BrokerOutboundQueue {
    typealias Sender = (Data, @escaping (Error?) -> Void) -> Void

    private struct Item {
        let generation: Int
        let data: Data
        let sender: Sender
        let onFailure: (Error) -> Void
    }

    private let state = DispatchQueue(label: "dev.universaltmux.websocket-send")
    private var generation: Int?
    private var pending: [Item] = []
    private var nextPending = 0
    private var sending = false

    func activate(generation: Int) {
        state.async {
            self.generation = generation
            self.pending.removeAll(keepingCapacity: true)
            self.nextPending = 0
            self.sending = false
        }
    }

    func deactivate() {
        state.async {
            self.generation = nil
            self.pending.removeAll(keepingCapacity: true)
            self.nextPending = 0
            self.sending = false
        }
    }

    func enqueue(
        _ frames: [Data],
        generation: Int,
        sender: @escaping Sender,
        onFailure: @escaping (Error) -> Void
    ) {
        guard !frames.isEmpty else { return }
        state.async {
            guard self.generation == generation else { return }
            self.pending.append(contentsOf: frames.map {
                Item(generation: generation, data: $0, sender: sender, onFailure: onFailure)
            })
            self.pump()
        }
    }

    private func pump() {
        guard !sending, let generation else { return }
        while nextPending < pending.count, pending[nextPending].generation != generation {
            nextPending += 1
        }
        guard nextPending < pending.count else {
            pending.removeAll(keepingCapacity: true)
            nextPending = 0
            return
        }

        let item = pending[nextPending]
        nextPending += 1
        if nextPending >= 256, nextPending * 2 >= pending.count {
            pending.removeFirst(nextPending)
            nextPending = 0
        }
        sending = true
        item.sender(item.data) { [weak self] error in
            self?.state.async {
                guard let self, self.generation == item.generation else { return }
                self.sending = false
                if let error {
                    self.pending.removeAll(keepingCapacity: true)
                    self.nextPending = 0
                    self.generation = nil
                    item.onFailure(error)
                    return
                }
                self.pump()
            }
        }
    }
}

/// Owns exactly one WebSocket generation and the URLSession that backs it.
///
/// URLSession retains task and callback state until the session is invalidated.
/// Sharing the app-wide HTTP session with every terminal reconnect therefore
/// lets retired WebSocket transports accumulate for the lifetime of the app.
/// Keeping the pair together gives every reconnect a hard ownership boundary:
/// invalidating this object cancels the task and releases its private session.
protocol BrokerTransportServing: AnyObject {
    func resume()
    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func ping(_ completion: @escaping (Error?) -> Void)
    func invalidate()
}

private final class BrokerSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let opened: () -> Void
    init(opened: @escaping () -> Void) { self.opened = opened }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async(execute: opened)
    }
}

final class BrokerWebSocketTransport: BrokerTransportServing {
    let session: URLSession
    let task: URLSessionWebSocketTask
    private(set) var isInvalidated = false

    init(url: URL, onOpen: @escaping () -> Void = {}) {
        let session = makeBrokerSession(configuration: .ephemeral, delegate: BrokerSocketDelegate(opened: onOpen))
        self.session = session
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
    }
    func resume() { task.resume() }
    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task.receive(completionHandler: completion)
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        task.send(.data(data), completionHandler: completion)
    }
    func ping(_ completion: @escaping (Error?) -> Void) { task.sendPing(pongReceiveHandler: completion) }
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        task.cancel()
        session.invalidateAndCancel()
    }
    deinit { invalidate() }
}

/// All lifecycle transitions run on the main queue. Transport callbacks from
/// retired epochs cannot change status, release new slots, or replay old input.
final class BrokerClient {
    typealias TransportFactory = (URL, @escaping () -> Void) -> any BrokerTransportServing
    private let traceID = String(UUID().uuidString.prefix(8))
    private let traceRef: String
    private var url: URL
    private var transport: (any BrokerTransportServing)?
    private var transportURL: URL?
    private var closed = false
    private var suspended = false
    private var live = false
    private var opened = false
    private var everConnected = false
    private var backoff: TimeInterval = 0.5
    private var epoch = 0
    private let outbound = BrokerOutboundQueue()
    private let scheduler: BrokerDialScheduler
    private let recovery: BrokerRecoveryConfiguration
    private let makeTransport: TransportFactory
    private var dialTicket: UUID?
    private var deadline: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var heartbeat: DispatchWorkItem?
    private var pingDeadline: DispatchWorkItem?
    private var pingID: UUID?
    private var lastTraffic: TimeInterval = 0
    private var recoveryObserver: NSObjectProtocol?
    private var backgroundRetention: BrokerBackgroundRetention?
    private var backgroundTimer: DispatchWorkItem?
    private var backgroundToken: UUID?
    private var backgroundBytes = 0

    var onOutput: (([UInt8]) -> Void)?
    var onPaneSize: ((_ cols: Int, _ rows: Int) -> Void)?
    var onSnapshot: ((Bool) -> Void)?
    var onStatus: ((ConnState) -> Void)?
    var onConnect: (() -> Void)?

    init(url: URL, traceRef: String, scheduler: BrokerDialScheduler = .shared,
         recovery: BrokerRecoveryConfiguration = .init(),
         observeNetwork: Bool = true,
         makeTransport: @escaping TransportFactory = { BrokerWebSocketTransport(url: $0, onOpen: $1) }) {
        self.url = url; self.traceRef = traceRef
        self.scheduler = scheduler; self.recovery = recovery; self.makeTransport = makeTransport
        if observeNetwork {
            _ = BrokerNetworkRecovery.shared
            recoveryObserver = NotificationCenter.default.addObserver(forName: BrokerNetworkRecovery.recovered, object: nil, queue: .main) { [weak self] _ in
                guard let self, !closed, !suspended else { return }
                backoff = 0.5
                if live { probeLiveness() }
                else if backgroundRetention == nil { nudge(trigger: "network-recovered") }
            }
        }
        trace("client_created")
    }

    var relaxed = false {
        didSet {
            guard oldValue != relaxed else { return }
            trace("reconnect_policy_changed", ["relaxed": relaxed])
            if let dialTicket { scheduler.prioritize(dialTicket, foreground: !relaxed) }
        }
    }

    /// Pause the local transport, not the remote session or its running jobs.
    /// Cached terminal history remains available; resume gets a fresh broker snapshot.
    func setSuspended(_ value: Bool) {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.setSuspended(value) }; return }
        guard !closed, suspended != value else { return }
        suspended = value
        if value {
            retire()
            trace("suspended")
            onStatus?(.suspended)
        } else {
            backoff = 0.5
            start(trigger: "resumed")
        }
    }

    /// A brief visibility/focus change must not throw away a healthy or still
    /// progressing connection. Repeated UI updates must not renew this lease.
    /// Hidden traffic and elapsed time independently bound its cost.
    func retainInBackground(_ budget: BrokerBackgroundRetention?) {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.retainInBackground(budget) }; return }
        guard !closed, backgroundRetention != budget else { return }
        backgroundTimer?.cancel(); backgroundTimer = nil; backgroundToken = nil
        backgroundRetention = budget
        backgroundBytes = 0
        guard let budget else {
            setSuspended(false)
            return
        }
        guard budget.grace > 0, budget.byteLimit > 0,
              !suspended, transport != nil || dialTicket != nil else {
            setSuspended(true)
            return
        }
        let token = UUID()
        backgroundToken = token
        trace("background_retained", ["seconds": budget.grace, "byteLimit": budget.byteLimit])
        let work = DispatchWorkItem { [weak self] in
            guard let self, backgroundToken == token else { return }
            trace("background_budget_expired", ["reason": "time", "bytes": backgroundBytes])
            setSuspended(true)
        }
        backgroundTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + budget.grace, execute: work)
    }

    func updateURL(_ value: URL) {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.updateURL(value) }; return }
        guard value != url else { return }
        url = value
        guard !closed, !suspended, !live else { return }
        backoff = 0.5
        start(trigger: "url-change")
    }

    func nudge(trigger: String = "visible") {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.nudge(trigger: trigger) }; return }
        guard !closed, !suspended else { return }
        if live {
            if ProcessInfo.processInfo.systemUptime - lastTraffic >= recovery.heartbeatInterval { probeLiveness() }
            return
        }
        // Revealing a pane must not restart an already progressing handshake.
        if let dialTicket { scheduler.prioritize(dialTicket, foreground: !relaxed); return }
        if transport != nil { return }
        backoff = 0.5
        trace("nudge", ["trigger": trigger])
        start(trigger: "nudge:\(trigger)")
    }

    func start(trigger: String = "initial") {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.start(trigger: trigger) }; return }
        guard !closed, !suspended else { return }
        retire()
        let ticket = UUID()
        dialTicket = ticket
        trace("dial_queued", ["trigger": trigger, "relaxed": relaxed])
        scheduler.request(id: ticket, host: "\(url.host ?? "?"):\(url.port ?? (url.scheme == "wss" ? 443 : 80))",
            foreground: !relaxed, grant: { [weak self] in
                guard let self, !closed, !suspended, dialTicket == ticket else { return }
                beginDial(trigger: trigger)
            }, revoke: { [weak self] in
                guard let self, dialTicket == ticket else { return }
                // The scheduler retains this ticket in its waiting queue.
                retire(releaseTicket: false)
                trace("dial_yielded")
            })
    }

    private func beginDial(trigger: String) {
        let current = epoch
        let connectedURL = url
        let transport = makeTransport(url) { [weak self] in
            guard let self else { return }
            onMain { [weak self] in self?.didOpen(current) }
        }
        self.transport = transport
        transportURL = connectedURL
        outbound.activate(generation: current)
        trace("dial_started", ["trigger": trigger, "epoch": current, "relaxed": relaxed])
        onStatus?(everConnected ? .reconnecting : .connecting)
        armDeadline(recovery.handshakeTimeout, event: "handshake_timeout", epoch: current)
        transport.resume()
        receiveLoop(current, connectedURL: connectedURL)
    }

    private func didOpen(_ current: Int) {
        guard valid(current), !opened else { return }
        opened = true
        trace("socket_opened", ["epoch": current])
        if !live { armDeadline(recovery.firstFrameTimeout, event: "first_frame_watchdog", epoch: current) }
        onConnect?()
        scheduleHeartbeat(current)
    }

    private func armDeadline(_ delay: TimeInterval, event: String, epoch current: Int) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, valid(current), !live else { return }
            trace(event, ["epoch": current, "delay": delay])
            fail(current, error: URLError(.timedOut))
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func receiveLoop(_ current: Int, connectedURL: URL) {
        transport?.receive { [weak self] result in
            self?.onMain { [weak self] in
                guard let self, valid(current) else { return }
                switch result {
                case .success(let message):
                    BrokerReachabilityEvidence.shared.record(url: connectedURL)
                    noteTraffic()
                    if !live {
                        live = true; everConnected = true; backoff = 0.5
                        deadline?.cancel(); deadline = nil
                        releaseDial()
                        trace("first_frame", ["epoch": current])
                        onStatus?(.connected)
                    }
                    if case .data(let data) = message { handle(data) }
                    if let budget = backgroundRetention {
                        switch message {
                        case .data(let data): backgroundBytes += data.count
                        case .string(let value): backgroundBytes += value.utf8.count
                        @unknown default: break
                        }
                        if backgroundBytes >= budget.byteLimit {
                            trace("background_budget_expired", ["reason": "bytes", "bytes": backgroundBytes])
                            setSuspended(true)
                            return
                        }
                    }
                    receiveLoop(current, connectedURL: connectedURL)
                case .failure(let error): fail(current, error: error)
                }
            }
        }
    }

    private func noteTraffic() {
        lastTraffic = ProcessInfo.processInfo.systemUptime
        pingID = nil; pingDeadline?.cancel(); pingDeadline = nil
    }

    private func scheduleHeartbeat(_ current: Int) {
        heartbeat?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, valid(current) else { return }
            if ProcessInfo.processInfo.systemUptime - lastTraffic >= recovery.heartbeatInterval { probeLiveness() }
            scheduleHeartbeat(current)
        }
        heartbeat = work
        DispatchQueue.main.asyncAfter(deadline: .now() + recovery.heartbeatInterval, execute: work)
    }

    private func probeLiveness() {
        guard !closed, !suspended, opened, pingID == nil, let transport, let connectedURL = transportURL else { return }
        let current = epoch, id = UUID()
        pingID = id
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, valid(current), pingID == id else { return }
            trace("heartbeat_timeout", ["epoch": current])
            fail(current, error: URLError(.timedOut))
        }
        pingDeadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + recovery.heartbeatTimeout, execute: timeout)
        transport.ping { [weak self] error in
            self?.onMain { [weak self] in
                guard let self, valid(current), pingID == id else { return }
                if let error { fail(current, error: error) }
                else {
                    noteTraffic()
                    BrokerReachabilityEvidence.shared.record(url: connectedURL)
                }
            }
        }
    }

    private func fail(_ current: Int, error: Error) {
        guard valid(current) else { return }
        trace("receive_failed", ["epoch": current, "error": error.localizedDescription])
        // Keeping a warm socket is cheap; reconnecting a hidden one is not.
        // Foreground promotion resumes immediately instead of waiting on backoff.
        if backgroundRetention != nil {
            setSuspended(true)
            return
        }
        retire()
        onStatus?(.reconnecting)
        let nextEpoch = epoch
        let delay = backoff * Double.random(in: 0.7...1.3)
        backoff = min(backoff * 2, relaxed ? 60 : 10)
        trace("reconnect_scheduled", ["epoch": nextEpoch, "delay": delay, "relaxed": relaxed])
        let work = DispatchWorkItem { [weak self] in
            guard let self, !closed, !suspended, epoch == nextEpoch else { return }
            start(trigger: "backoff-retry")
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stop() {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.stop() }; return }
        closed = true
        backgroundTimer?.cancel(); backgroundTimer = nil; backgroundToken = nil
        retire()
        trace("client_stopped")
    }

    private func valid(_ current: Int) -> Bool { !closed && !suspended && epoch == current && transport != nil }
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
    private func releaseDial() {
        if let dialTicket { scheduler.release(dialTicket); self.dialTicket = nil }
    }
    private func retire(releaseTicket: Bool = true) {
        epoch &+= 1
        deadline?.cancel(); deadline = nil
        retry?.cancel(); retry = nil
        heartbeat?.cancel(); heartbeat = nil
        pingDeadline?.cancel(); pingDeadline = nil; pingID = nil
        outbound.deactivate()
        let previous = transport
        transport = nil; transportURL = nil; live = false; opened = false
        previous?.invalidate()
        if releaseTicket { releaseDial() }
    }
    deinit {
        backgroundTimer?.cancel()
        deadline?.cancel(); retry?.cancel(); heartbeat?.cancel(); pingDeadline?.cancel()
        if let recoveryObserver { NotificationCenter.default.removeObserver(recoveryObserver) }
        if let dialTicket { scheduler.release(dialTicket) }
        transport?.invalidate()
        outbound.deactivate()
    }

    private func trace(_ event: String, _ fields: [String: Any] = [:]) {
        var all = fields
        all["client"] = traceID; all["ref"] = traceRef
        all["target"] = "\(url.host ?? "?")\(url.path)"
        TerminalConnectionTrace.record("broker.\(event)", all)
    }

    private func handle(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }
        let paneLength = Int(bytes[1])
        guard bytes.count >= 2 + paneLength else { return }
        let payload = bytes[(2 + paneLength)...]
        switch bytes[0] {
        case Op.output: onOutput?(Array(payload))
        case Op.snapshotBegin: onSnapshot?(true)
        case Op.snapshotEnd: onSnapshot?(false)
        case Op.paneSize:
            guard payload.count >= 4 else { return }
            let i = payload.startIndex
            onPaneSize?(Int(payload[i]) << 8 | Int(payload[i + 1]),
                        Int(payload[i + 2]) << 8 | Int(payload[i + 3]))
        default: break
        }
    }

    func send(op: UInt8, pane: String, payload: [UInt8]) {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.send(op: op, pane: pane, payload: payload) }; return }
        guard !suspended, let transport else { return }
        let current = epoch
        outbound.enqueue(BrokerWireFrames.encode(op: op, pane: pane, payload: payload), generation: current,
            sender: { [weak transport] data, completion in
                guard let transport else { completion(CancellationError()); return }
                transport.send(data, completion: completion)
            }, onFailure: { [weak self] error in
                self?.onMain { [weak self] in self?.fail(current, error: error) }
            })
    }
}
