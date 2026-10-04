import Foundation

/// One live terminal WebSocket (`/ws?session=`), following the broker's
/// attach contract: the broker sends nothing until the first RESIZE; it then
/// emits PANE_SIZE, an idempotent snapshot (which clears scrollback), and live
/// output. Reconnects with jittered backoff; input is never replayed into a new
/// socket.
@MainActor
final class TerminalConnection: NSObject, ObservableObject {
    enum State: Equatable { case connecting, connected, reconnecting, closed }

    @Published private(set) var state: State = .connecting
    @Published private(set) var paneSize: (cols: Int, rows: Int)? = nil {
        didSet { paneSizeVersion += 1 }
    }
    @Published private(set) var paneSizeVersion = 0

    var onOutput: ((ArraySlice<UInt8>) -> Void)?

    let machine: Machine
    let handle: String

    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var backoff: TimeInterval = 0.5
    private var requested: (cols: Int, rows: Int)?
    private var snapshotDebounce: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var outbound: [Data] = []
    private var sending = false
    private var closedByUser = false

    private lazy var urlSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    init(machine: Machine, handle: String) {
        self.machine = machine
        self.handle = handle
    }

    var url: URL {
        var c = URLComponents(url: machine.wsBase.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "session", value: handle)]
        return c.url!
    }

    private var demoLine = ""
    private var demoScreenPending = false

    func connect() {
        if DemoFleet.isDemo(machine) { return connectDemo() }
        closedByUser = false
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        outbound.removeAll()
        sending = false
        state = generation == 1 ? .connecting : .reconnecting
        let t = urlSession.webSocketTask(with: url)
        t.maximumMessageSize = 64 << 20   // snapshots carry up to 10k lines of history
        task = t
        t.resume()
        // Priming: the broker answers only after our grid request.
        if let r = requested { enqueue(WireFrame.resize(cols: r.cols, rows: r.rows)) }
        receive(gen)
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.generation == gen else { return }
                self.task?.sendPing { _ in }
            }
        }
    }

    func close() {
        closedByUser = true
        generation += 1
        pingTask?.cancel()
        snapshotDebounce?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .closed
    }

    /// The grid this phone can show. Sent on connect and when it changes; the
    /// broker's PANE_SIZE stays authoritative.
    func requestSize(cols: Int, rows: Int) {
        let c = min(max(cols, 2), 1000), r = min(max(rows, 2), 1000)
        if let q = requested, q.cols == c, q.rows == r { return }
        requested = (c, r)
        if DemoFleet.isDemo(machine) {
            paneSize = (c, r)
            if demoScreenPending { demoScreenPending = false; emitDemoScreen() }
            return
        }
        if task != nil { enqueue(WireFrame.resize(cols: c, rows: r)) }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        if DemoFleet.isDemo(machine) { return demoInput(bytes) }
        for f in WireFrame.encode(op: Op.input, payload: Array(bytes)) { enqueue(f) }
    }

    func requestSnapshot() { enqueue(WireFrame.encode(op: Op.requestSnapshot)[0]) }

    // MARK: Demo

    /// The demo fleet has no socket: render the session and answer commands locally.
    private func connectDemo() {
        closedByUser = false
        state = .connected
        // Like a real broker: nothing is drawn until the terminal has a size.
        guard let r = requested else { demoScreenPending = true; return }
        paneSize = r
        emitDemoScreen()
    }

    private func emitDemoScreen() {
        onOutput?(ArraySlice(Array(DemoShell.screen(machine: machine, handle: handle).utf8)))
    }

    private func demoInput(_ bytes: ArraySlice<UInt8>) {
        var echo = ""
        for b in bytes {
            switch b {
            case 0x0d, 0x0a:
                let reply = DemoShell.run(demoLine)
                echo += "\r\n" + (reply.isEmpty ? "" : reply.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n") + "$ "
                demoLine = ""
            case 0x7f, 0x08:
                if !demoLine.isEmpty { demoLine.removeLast(); echo += "\u{8} \u{8}" }
            case 0x20...0x7e:
                demoLine.append(Character(UnicodeScalar(b))); echo.append(Character(UnicodeScalar(b)))
            default: break
            }
        }
        if !echo.isEmpty { onOutput?(ArraySlice(Array(echo.utf8))) }
    }

    // MARK: Socket

    private func receive(_ gen: Int) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                switch result {
                case .success(let message):
                    if case .data(let data) = message { self.handle(data) }
                    self.receive(gen)
                case .failure:
                    self.dropped(gen)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let frame = WireFrame.decode(data) else { return }
        if state != .connected { state = .connected; backoff = 0.5 }
        switch frame.op {
        case Op.output:
            onOutput?(frame.payload)
        case Op.paneSize:
            guard let size = WireFrame.paneSize(frame.payload) else { return }
            let changed = paneSize.map { $0.cols != size.cols || $0.rows != size.rows } ?? true
            paneSize = size
            // After the terminal re-pins, ask for a clean repaint at the new grid.
            if changed {
                snapshotDebounce?.cancel()
                snapshotDebounce = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    self?.requestSnapshot()
                }
            }
        default:
            break   // unknown ops are ignored by contract
        }
    }

    private func dropped(_ gen: Int) {
        guard !closedByUser, generation == gen else { return }
        state = .reconnecting
        let delay = backoff * Double.random(in: 0.8...1.2)
        backoff = min(backoff * 2, 10)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.closedByUser, self.generation == gen else { return }
            self.connect()
        }
    }

    /// One frame in flight at a time, so bracketed pastes and key sequences
    /// keep their order.
    private func enqueue(_ data: Data) {
        outbound.append(data)
        pump()
    }

    private func pump() {
        guard !sending, let task, !outbound.isEmpty else { return }
        sending = true
        let data = outbound.removeFirst()
        let gen = generation
        task.send(.data(data)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.sending = false
                if error != nil { self.dropped(gen) } else { self.pump() }
            }
        }
    }
}
