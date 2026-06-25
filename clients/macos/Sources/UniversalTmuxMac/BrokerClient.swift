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

    init(url: URL) { self.url = url }

    /// Point (re)connections at a new session URL. On a LIVE socket this only
    /// affects future reconnects, so a seamless rename keeps streaming (the broker
    /// holds the session open across the rename). When NOT live — e.g. stuck
    /// reconnecting because the session's stable id ($N) went stale after it was
    /// re-created (resumed from history) — adopt the new URL and reconnect at once,
    /// so it dials the new id immediately instead of waiting out the backoff.
    func updateURL(_ u: URL) {
        guard u != url else { return }
        url = u
        guard !closed, !live else { return }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        backoff = 0.5
        start()
    }

    func start() {
        guard !closed else { return }
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
        onStatus?(everConnected ? .reconnecting : .connecting)
        onConnect?() // queued by URLSession until the socket opens; re-sends geometry
        receiveLoop(myEpoch)
    }

    func stop() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop(_ myEpoch: Int) {
        task?.receive { [weak self] result in
            // A reconnect (or updateURL) bumps `epoch`; a callback from a superseded
            // socket bails so we never run two receive loops at once.
            guard let self, !self.closed, myEpoch == self.epoch else { return }
            switch result {
            case .success(let message):
                if !self.live {
                    self.live = true
                    self.everConnected = true
                    self.backoff = 0.5
                    self.onStatus?(.connected)
                }
                if case .data(let data) = message { self.handle(data) }
                self.receiveLoop(myEpoch)
            case .failure:
                guard !self.closed, myEpoch == self.epoch else { return }
                self.live = false
                self.onStatus?(.reconnecting)
                self.scheduleReconnect(myEpoch)
            }
        }
    }

    private func scheduleReconnect(_ myEpoch: Int) {
        let delay = backoff
        backoff = min(backoff * 2, 10) // 0.5,1,2,4,8,10,10…
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed, myEpoch == self.epoch else { return }
            self.start()
        }
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
