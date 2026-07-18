import Foundation

enum Op {
    static let output: UInt8 = 1
    static let input: UInt8 = 2
    static let resize: UInt8 = 3
    static let requestSnapshot: UInt8 = 4 // ask the broker for a fresh authoritative redraw
    static let paneSize: UInt8 = 5 // broker → us: the pane's AUTHORITATIVE cols×rows.
    // %output bytes are formatted for exactly this grid; rendering at any other
    // width shears the screen, so the terminal pins to it (opResize is only an ask).
}

/// Live state of a broker socket, surfaced to the UI (header status chip).
enum ConnState: Equatable {
    case connecting, connected, reconnecting, closed
}

/// One WebSocket connection to a broker session (binary frame protocol).
/// Auto-reconnects with exponential backoff; fires `onConnect` on every
/// (re)connect so the owner can re-send the pane geometry.
final class BrokerClient {
    private let traceID = String(UUID().uuidString.prefix(8))
    private let traceRef: String
    private var url: URL
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var live = false          // received at least one frame on the current socket
    private var everConnected = false // distinguishes first connect from a reconnect
    private var backoff: TimeInterval = 0.5
    private var epoch = 0             // bumped on each start(); a stale receive/reconnect callback bails on mismatch (no double socket)

    var onOutput: (([UInt8]) -> Void)?
    var onPaneSize: ((_ cols: Int, _ rows: Int) -> Void)?  // authoritative pane size (op 5)
    var onStatus: ((ConnState) -> Void)?
    var onConnect: (() -> Void)?      // each (re)connect — used to re-send geometry

    init(url: URL, traceRef: String) {
        self.url = url
        self.traceRef = traceRef
        trace("client_created")
    }

    /// Point (re)connections at a new session URL. On a LIVE socket this only
    /// affects future reconnects, so a seamless rename keeps streaming (the broker
    /// holds the session open across the rename). When NOT live — e.g. stuck
    /// reconnecting because the session's stable id ($N) went stale after it was
    /// re-created (resumed from history) — adopt the new URL and reconnect at once,
    /// so it dials the new id immediately instead of waiting out the backoff.
    func updateURL(_ u: URL) {
        guard u != url else { return }
        let oldTarget = targetDescription
        url = u
        trace("url_changed", ["oldTarget": oldTarget, "live": live])
        guard !closed, !live else { return }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        backoff = 0.5
        start(trigger: "url-change")
    }

    // ---- thundering-herd control -------------------------------------------
    // At app (re)launch every pane dials at once. A burst of simultaneous flows
    // from one client can poison the broker's tsnet data plane for MINUTES (flows
    // handshake, then frames blackhole), and the resulting mass flapping both
    // sustains the blackhole and storms SwiftUI with connection-state churn.
    // Two standard measures: PACE dials per host (max a few in the connecting
    // state at once) and JITTER the backoff so retries can't march in waves.
    private static let paceLock = NSLock()
    private static var dialing: [String: Int] = [:]   // host → conns in pre-first-frame state
    private static let maxDialingPerHost = 3

    private var pacedHost: String?   // host this conn currently counts against
    private func paceRelease() {
        guard let h = pacedHost else { return }
        pacedHost = nil
        Self.paceLock.lock()
        Self.dialing[h] = max(0, (Self.dialing[h] ?? 1) - 1)
        Self.paceLock.unlock()
    }

    /// Broker ALWAYS sends the pane-size frame right after accept, so a socket
    /// that opens but stays silent is a poisoned flow (blackholed in transit) —
    /// it will never error out on its own. Recycle it.
    private var firstFrameWork: DispatchWorkItem?

    /// HIDDEN panes reconnect lazily (60s backoff cap, 45s watchdog) instead of
    /// hot-recycling every few seconds: with a flapping broker, N background
    /// panes churning connection state was enough continuous invalidation to
    /// pin SwiftUI layout on macOS 26 (the whole-Mac "hanging" storms). The
    /// visible pane keeps the snappy caps, and unhiding nudges an immediate dial.
    var relaxed = false {
        didSet {
            if oldValue != relaxed { trace("reconnect_policy_changed", ["relaxed": relaxed]) }
        }
    }
    private var backoffCap: Double { relaxed ? 60 : 10 }
    private var watchdogDelay: Double { relaxed ? 45 : 6 }

    /// Un-hidden and not live → dial NOW (skip whatever long backoff remains).
    func nudge(trigger: String = "visible") {
        guard !closed else {
            trace("nudge_skipped", ["reason": "closed", "trigger": trigger])
            return
        }
        guard !live else {
            trace("nudge_skipped", ["reason": "already-live", "trigger": trigger])
            return
        }
        trace("nudge", ["trigger": trigger, "hadTask": task != nil, "epoch": epoch])
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        backoff = 0.5
        start(trigger: "nudge:\(trigger)")
    }

    func start(trigger: String = "initial") {
        guard !closed else { return }
        // NO GHOSTS: a superseded dial/socket must die here, not linger. start()
        // used to just overwrite `task`; during restart churn (updateURL fires as
        // /sessions refreshes tmux ids, while a pacing gate-retry is pending) that
        // orphaned LIVE sockets — open on the broker, frames ignored client-side,
        // never cancelled — inflating the very per-pair flow pressure that causes
        // the babel blackhole. Cancel first, always.
        if task != nil { trace("dial_superseded", ["trigger": trigger, "epoch": epoch]) }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // Re-entry safety (found by the git-insights review): updateURL — and any
        // future caller — can restart mid-dial while this client still holds a
        // pacing slot; the abandoned dial's callbacks bail on the epoch check and
        // would never release it. Release before claiming anew.
        paceRelease()
        let host = url.host ?? "?"
        Self.paceLock.lock()
        let inFlight = Self.dialing[host] ?? 0
        if inFlight >= Self.maxDialingPerHost {
            Self.paceLock.unlock()
            trace("pace_wait", ["trigger": trigger, "inFlight": inFlight, "epoch": epoch])
            // Too many conns to this host mid-dial — wait a beat and retry the
            // gate. STALENESS GUARD: only if nothing superseded this attempt
            // (epoch unchanged) and the pane didn't connect meanwhile — a stale
            // retry used to tear down a healthy connection and redial it, which
            // showed as a pane flipping to "reconnecting" for no reason.
            let retryEpoch = epoch
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.4...1.2)) { [weak self] in
                guard let self, !self.closed, self.epoch == retryEpoch, !self.live else { return }
                self.start(trigger: "pace-retry")
            }
            return
        }
        Self.dialing[host] = inFlight + 1
        Self.paceLock.unlock()
        pacedHost = host

        epoch &+= 1
        let myEpoch = epoch
        let t = URLSession.shared.webSocketTask(with: url)
        // A session's scrollback snapshot can exceed URLSession's default 1 MiB
        // message cap — which fails the receive with EMSGSIZE and, since the
        // reconnect re-sends it, loops forever ("reconnecting"). The broker now
        // chunks large frames; this raised cap is belt-and-suspenders (and fixes
        // it immediately against any broker not yet updated).
        t.maximumMessageSize = 64 * 1024 * 1024
        task = t
        live = false
        t.resume()
        trace("dial_started", ["trigger": trigger, "epoch": myEpoch, "state": everConnected ? "reconnecting" : "connecting", "relaxed": relaxed])
        onStatus?(everConnected ? .reconnecting : .connecting)
        onConnect?() // queued by URLSession until the socket opens; re-sends geometry
        firstFrameWork?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.closed, myEpoch == self.epoch, !self.live else { return }
            // Opened but silent for 6s — poisoned flow. Cancel; the receive
            // failure path reconnects with jittered backoff.
            self.trace("first_frame_watchdog", ["epoch": myEpoch, "delay": self.watchdogDelay])
            self.task?.cancel(with: .goingAway, reason: nil)
        }
        firstFrameWork = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogDelay, execute: watchdog)
        receiveLoop(myEpoch)
    }

    // Insurance for the static pacing registry (flagged by the git-insights
    // review): a client deallocated without stop() must not leak its dial slot —
    // that would silently cap its host below maxDialingPerHost forever.
    deinit {
        firstFrameWork?.cancel()
        paceRelease()
        // URLSession owns the task independently of this object — without an
        // explicit cancel a dealloc'd client leaves the socket running against
        // the broker (found by the insights ask-review of this very fix).
        task?.cancel(with: .goingAway, reason: nil)
    }

    func stop() {
        trace("client_stopped", ["epoch": epoch, "live": live])
        closed = true
        firstFrameWork?.cancel()
        paceRelease()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop(_ myEpoch: Int) {
        task?.receive { [weak self] result in
            // A reconnect (or updateURL) bumps `epoch`; a callback from a superseded
            // socket bails so we never run two receive loops at once.
            guard let self, !self.closed else { return }
            guard myEpoch == self.epoch else {
                self.trace("stale_receive_ignored", ["callbackEpoch": myEpoch, "epoch": self.epoch])
                return
            }
            switch result {
            case .success(let message):
                if !self.live {
                    self.live = true
                    self.everConnected = true
                    self.backoff = 0.5
                    self.firstFrameWork?.cancel()
                    self.paceRelease()
                    self.trace("first_frame", ["epoch": myEpoch])
                    self.onStatus?(.connected)
                }
                if case .data(let data) = message { self.handle(data) }
                self.receiveLoop(myEpoch)
            case .failure(let error):
                guard !self.closed, myEpoch == self.epoch else { return }
                self.live = false
                self.firstFrameWork?.cancel()
                self.paceRelease()
                self.trace("receive_failed", ["epoch": myEpoch, "error": error.localizedDescription])
                self.onStatus?(.reconnecting)
                self.scheduleReconnect(myEpoch)
            }
        }
    }

    private func scheduleReconnect(_ myEpoch: Int) {
        let delay = backoff * Double.random(in: 0.7...1.3)   // jitter: no synchronized waves
        backoff = min(backoff * 2, backoffCap) // 0.5,1,2,4,8,… capped (60s when hidden)
        trace("reconnect_scheduled", ["epoch": myEpoch, "delay": delay, "nextBackoff": backoff, "relaxed": relaxed])
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed, myEpoch == self.epoch else { return }
            self.start(trigger: "backoff-retry")
        }
    }

    private var targetDescription: String {
        let session = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "session" })?.value ?? ""
        return "\(url.host ?? "?")\(url.path)#\(session)"
    }

    private func trace(_ event: String, _ fields: [String: Any] = [:]) {
        var all = fields
        all["client"] = traceID
        all["ref"] = traceRef
        all["target"] = targetDescription
        TerminalConnectionTrace.record("broker.\(event)", all)
    }

    private func handle(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 2 else { return }
        let op = b[0]
        let paneLen = Int(b[1])
        guard b.count >= 2 + paneLen else { return }
        let payload = b[(2 + paneLen)...]
        switch op {
        case Op.output:
            onOutput?(Array(payload))
        case Op.paneSize:
            guard payload.count >= 4 else { return }
            let i = payload.startIndex
            let cols = Int(payload[i]) << 8 | Int(payload[i + 1])
            let rows = Int(payload[i + 2]) << 8 | Int(payload[i + 3])
            onPaneSize?(cols, rows)
        default:
            break
        }
    }

    func send(op: UInt8, pane: String, payload: [UInt8]) {
        var frame = [UInt8]()
        let p = Array(pane.utf8)
        frame.append(op)
        frame.append(UInt8(p.count & 0xff))
        frame.append(contentsOf: p)
        frame.append(contentsOf: payload)
        task?.send(.data(Data(frame))) { _ in }
    }
}
