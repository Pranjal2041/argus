import Foundation

enum Op {
    static let output: UInt8 = 1
    static let input: UInt8 = 2
    static let resize: UInt8 = 3
    static let requestSnapshot: UInt8 = 4 // ask the broker for a fresh authoritative redraw
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

    var onOutput: (([UInt8]) -> Void)?
    var onStatus: ((ConnState) -> Void)?
    var onConnect: (() -> Void)?      // each (re)connect — used to re-send geometry

    init(url: URL) { self.url = url }

    /// Point future (re)connections at a new session URL without tearing down the
    /// current live socket — used for a seamless rename (the broker keeps the
    /// session streaming, so the open socket stays valid; only reconnects need the
    /// new name).
    func updateURL(_ u: URL) { url = u }

    func start() {
        guard !closed else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        live = false
        t.resume()
        onStatus?(everConnected ? .reconnecting : .connecting)
        onConnect?() // queued by URLSession until the socket opens; re-sends geometry
        receiveLoop()
    }

    func stop() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let message):
                if !self.live {
                    self.live = true
                    self.everConnected = true
                    self.backoff = 0.5
                    self.onStatus?(.connected)
                }
                if case .data(let data) = message { self.handle(data) }
                self.receiveLoop()
            case .failure:
                guard !self.closed else { return }
                self.live = false
                self.onStatus?(.reconnecting)
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        let delay = backoff
        backoff = min(backoff * 2, 10) // 0.5,1,2,4,8,10,10…
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed else { return }
            self.start()
        }
    }

    private func handle(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 2 else { return }
        let op = b[0]
        let paneLen = Int(b[1])
        guard b.count >= 2 + paneLen else { return }
        if op == Op.output { onOutput?(Array(b[(2 + paneLen)...])) }
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
