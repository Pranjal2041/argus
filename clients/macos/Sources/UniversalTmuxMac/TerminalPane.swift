import AppKit
import SwiftTerm
import SwiftUI

/// One live terminal: a SwiftTerm view + its broker connection + delegate.
/// Kept alive for the lifetime of the app session so switching away and back
/// preserves scrollback and the connection (no reconnect, no reload).
private struct PasteHome: Decodable { let home: String; let sep: String }

final class PaneConn: NSObject, TerminalViewDelegate {
    let view: TerminalView
    private let client: BrokerClient
    private let httpBase: String   // broker http(s) base, for uploading pasted images
    private(set) var connURL: URL  // the session URL this conn (re)connects to; changes on rename or resume (new tmux id)
    private var lastPane = ""

    /// Forwarded live connection state (for the header status chip).
    var onState: ((ConnState) -> Void)?
    /// Forwarded scroll position (0=top … 1=bottom) for the jump-to-bottom pill.
    var onScroll: ((Double) -> Void)?
    /// A clicked file PATH (not a web URL) on this pane's host, with an optional
    /// line number — routed to the host's Files window instead of the local Mac.
    var onOpenPath: ((_ path: String, _ line: Int?) -> Void)?
    /// A clicked `localhost:port` dashboard URL on this pane's host — routed to the
    /// embedded Dashboards window (auto-forwarding the port if the host is remote).
    var onOpenLocalhost: ((_ port: Int, _ path: String, _ scheme: String) -> Void)?
    /// W&B runs this session has advertised in its output (latest last). Fires when
    /// the detected set changes — drives the in-place W&B webview.
    var onWandbRuns: (([WandbRun]) -> Void)?

    // Output scanned for W&B run URLs — the raw STREAM, not the screen, so a URL the
    // terminal visually wrapped (or one deep in the connect snapshot's scrollback)
    // stays whole. We scan ALL output and reset, keeping a small tail to bridge a URL
    // split across scans — so a URL is NEVER discarded unscanned. (The old code kept a
    // rolling 48KB tail and scanned only that, so a run sitting earlier than the last
    // 48KB of a long reconnect snapshot was trimmed away → vanished on reopen.)
    private var wandbBuf: [UInt8] = []
    private var wandbTail = ""
    private var wandbScan: DispatchWorkItem?

    /// (Re)apply the active theme to this pane's terminal. Called at creation and again
    /// whenever the user switches themes — recolors in place, no reconnect, scrollback kept.
    func applyTheme() {
        view.installColors(Theme.ansi16)
        view.nativeBackgroundColor = Theme.nsAppBackground
        view.nativeForegroundColor = Theme.nsForeground
        view.caretColor = Theme.nsCursor
        view.caretTextColor = Theme.nsCursorText
        view.selectedTextBackgroundColor = Theme.nsSelection
        view.layer?.backgroundColor = Theme.nsAppBackground.cgColor
        view.needsDisplay = true
    }

    init(url: URL) {
        view = TerminalView(frame: .zero)
        client = BrokerClient(url: url)
        httpBase = PaneConn.httpBase(from: url)
        connURL = url
        super.init()
        view.terminalDelegate = self
        // Keep text selectable. With mouse reporting ON (SwiftTerm's default),
        // feedPrepare() clears the selection on EVERY feed, so a periodically
        // redrawing TUI (an agent) makes text impossible to select/copy — and a
        // drag is sent to the remote app as mouse events instead of selecting.
        // This is a copy-focused viewer, so prefer local selection; the keyboard
        // still drives the agent fully. (Could become a per-session toggle.)
        view.allowMouseReporting = false
        view.getTerminal().changeScrollback(100_000) // large client-side scrollback (default is 500)
        // Seamless theme: terminal background == window background. Applied here and
        // re-applied live on theme switch (see applyTheme + TerminalController).
        applyTheme()
        client.onOutput = { [weak self] bytes in
            DispatchQueue.main.async {
                guard let self else { return }
                self.view.feed(byteArray: bytes[...])
                self.ingestForWandb(bytes)
            }
        }
        // The pane's AUTHORITATIVE size (connect + every remote resize): pin the
        // grid to exactly this and ask for a clean repaint. Arrives in stream
        // order relative to output, so the re-pin lands precisely between bytes
        // formatted for the old width and bytes formatted for the new.
        client.onPaneSize = { [weak self] cols, rows in
            DispatchQueue.main.async { self?.setPin(cols: cols, rows: rows) }
        }
        client.onStatus = { [weak self] st in DispatchQueue.main.async { self?.onState?(st) } }
        // On every (re)connect, push the current geometry so the remote pane
        // adopts the live window size instead of tmux's default.
        client.onConnect = { [weak self] in
            DispatchQueue.main.async { self?.sendCurrentGeometry() }
        }
        client.start()
    }

    func disconnect() { client.stop() }

    // MARK: W&B run detection (off the raw output stream)

    private func ingestForWandb(_ bytes: [UInt8]) {
        wandbBuf.append(contentsOf: bytes)
        // A big reconnect snapshot can arrive faster than the debounce — scan-and-flush
        // eagerly so it's neither lost to a cap nor held unbounded; the tail bridges any
        // URL straddling the flush boundary.
        if wandbBuf.count >= 512 * 1024 { wandbScan?.cancel(); scanWandb(); return }
        wandbScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanWandb() }
        wandbScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func scanWandb() {
        guard !wandbBuf.isEmpty else { return }
        let text = wandbTail + String(decoding: wandbBuf, as: UTF8.self)
        wandbBuf.removeAll(keepingCapacity: true)
        wandbTail = String(text.suffix(8 * 1024))   // overlap so a URL split across scans rejoins
        let runs = WandbDetector.runs(in: text)
        // mergeWandb (the receiver) unions + dedups by id and persists only on a real
        // change, so re-emitting an already-known run each window is cheap/idempotent.
        if !runs.isEmpty { onWandbRuns?(runs) }
    }

    /// Repoint this live connection at the renamed session's URL. The open socket
    /// is left untouched (the broker keeps streaming across the rename); only a
    /// future reconnect uses the new URL.
    func rename(to newURL: URL) { connURL = newURL; client.updateURL(newURL) }

    /// Send raw input to this pane's active pane (op=input, empty pane id).
    func sendInput(_ text: String) {
        client.send(op: Op.input, pane: lastPane, payload: Array(text.utf8))
    }

    // MARK: image paste (bridge the Mac clipboard to the remote agent)

    /// Upload a pasted clipboard image to the session's HOST and type its path into
    /// the agent. A remote agent (claude/codex on Babel/Windows) can't read the
    /// Mac's clipboard, so this is the file-path-bridge approach the community uses.
    func handleImagePaste(_ png: Data) {
        guard !httpBase.isEmpty else { return }
        Task {
            var home = "", sep = "/"
            if let u = URL(string: httpBase + "/fs/home"),
               let (d, _) = try? await URLSession.shared.data(from: u),
               let h = try? JSONDecoder().decode(PasteHome.self, from: d) {
                home = h.home; sep = h.sep
            }
            guard !home.isEmpty else { return }
            let folder = home + sep + ".argus-pastes"
            _ = await self.fsPost("/fs/mkdir", query: ["path": folder])   // ok if it already exists
            let path = folder + sep + "paste-\(UUID().uuidString.prefix(8)).png"
            if await self.fsWrite(path: path, data: png) {
                DispatchQueue.main.async { self.sendInput(path + " ") }
            } else {
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    @discardableResult
    private func fsPost(_ ep: String, query: [String: String]) async -> Bool {
        guard var c = URLComponents(string: httpBase + ep) else { return false }
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func fsWrite(path: String, data: Data) async -> Bool {
        guard var c = URLComponents(string: httpBase + "/fs/write") else { return false }
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = c.url else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// http(s) base for the broker, derived from its ws(s) URL.
    private static func httpBase(from ws: URL) -> String {
        var c = URLComponents(url: ws, resolvingAgainstBaseURL: false)
        c?.scheme = (ws.scheme == "wss") ? "https" : "http"
        c?.path = ""; c?.query = nil
        return c?.string ?? ""
    }

    /// Style the enclosing scroller to an unobtrusive dark overlay (best-effort).
    func styleScroller() {
        if let sv = view.enclosingScrollView {
            sv.scrollerStyle = .overlay
            sv.scrollerKnobStyle = .light
            sv.hasVerticalScroller = true
        }
    }

    // MARK: authoritative pane size (the anti-shear pin)
    //
    // A tmux pane has exactly ONE width at a time, negotiated across ALL of its
    // clients (a real `tmux attach` terminal, this app, the phone — any of them
    // can win). The %output bytes are formatted for that width, so this view must
    // render at EXACTLY that grid or every full-width line shears. The broker
    // pushes that size (opPaneSize) on connect and on every change; we pin the
    // grid to it by sizing the view's frame to exactly that many cells inside the
    // container (spare pixels letterbox in the matching background color). Our own
    // size wishes (opResize) are asks computed from the CONTAINER's bounds —
    // whatever tmux decides comes back as the next opPaneSize.
    private(set) var pinnedCols = 0  // 0 = unpinned (old broker): view just fills the container
    private(set) var pinnedRows = 0

    private func setPin(cols: Int, rows: Int) {
        guard cols >= 2, cols <= 1000, rows >= 2, rows <= 1000 else { return }
        guard cols != pinnedCols || rows != pinnedRows else { return }
        pinnedCols = cols
        pinnedRows = rows
        applyLayout()
        // The pin event IS tmux's confirmation that the reflow happened, so a
        // snapshot captured now is at the confirmed width — the deterministic
        // redraw the old timed-guess approach couldn't provide. Debounced so a
        // drag-resize storm coalesces into one repaint of the settled size.
        scheduleSnapshotRedraw()
    }

    /// The user's chosen font — the MAXIMUM the pane renders at. When a wider
    /// client owns the window (pin > what fits here), the DISPLAY font shrinks
    /// just enough that the whole pane stays visible (fit-to-pane, VNC-style);
    /// it snaps back to this the moment the pin fits again. Clipping instead
    /// would hide live content (e.g. the prompt at the bottom) with no way to
    /// reach it.
    private var preferredFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

    func setPreferredFont(_ f: NSFont) {
        preferredFont = f
        view.font = f          // start at the max; applyLayout shrinks if the pin demands
        applyLayout()
        sendCurrentGeometry()
    }

    /// Frame the view inside its container: exactly the pinned grid when pinned
    /// (letterboxed, font shrunk to fit if needed), else fill the container
    /// (legacy broker). Called from the container's layout pass, on pin changes,
    /// and after font changes.
    func applyLayout() {
        guard let sv = view.superview else { return }
        let bounds = sv.bounds
        if pinnedCols > 0 && pinnedRows > 0 {
            if bounds.width > 1, bounds.height > 1 {
                // Fit-to-pane: largest display size ≤ preferred where the whole
                // pinned grid is visible. Cell metrics scale ~linearly with point
                // size; the recompute below corrects any snapping drift, and the
                // 0.25pt hysteresis stops micro-oscillation.
                let needed = view.frameSize(forCols: pinnedCols, rows: pinnedRows)
                let scale = min(bounds.width / needed.width, bounds.height / needed.height)
                let current = view.font.pointSize
                let target = min(preferredFont.pointSize, max(6, current * scale))
                if abs(target - current) > 0.25 {
                    view.font = NSFont(descriptor: preferredFont.fontDescriptor, size: target) ?? preferredFont
                }
            }
            view.frame = CGRect(origin: .zero, size: view.frameSize(forCols: pinnedCols, rows: pinnedRows))
        } else {
            if view.font.pointSize != preferredFont.pointSize {
                view.font = preferredFont
            }
            view.frame = bounds
        }
    }

    /// The grid that would fill the container at the PREFERRED font — what we ask
    /// tmux for. Computed DIRECTLY from the preferred font's cell metrics, never
    /// the current display font: when a wider co-attached client forces a
    /// fit-to-pane shrink, deriving the ask from the shrunk font (and scaling back
    /// by a point-size ratio) drifts — cells are ceil-snapped to pixels, so the
    /// scaling is non-linear — and collapsed the ask to a tiny grid, which then
    /// became the window and left a huge letterboxed strip. Preferred metrics make
    /// the ask a pure function of (container, preferred font): no feedback loop.
    private func naturalGrid(in size: CGSize) -> (cols: Int, rows: Int) {
        let g = view.gridSize(for: size, font: preferredFont)
        return (cols: max(2, g.cols), rows: max(2, g.rows))
    }

    /// Ask the broker for this pane's preferred size: the grid that would fill
    /// the CONTAINER (not the pinned view) at preferred-font metrics. Immediate
    /// (non-debounced) — used on connect, show, and clear.
    ///
    /// Gated on a real, laid-out container: a zero/degenerate frame yields a
    /// bogus 1–2 column grid, and that — as the broker's FIRST resize — would
    /// prime the snapshot at 2 columns wide (the blank/garbled new pane).
    func sendCurrentGeometry() {
        guard let sv = view.superview, sv.bounds.width > 1, sv.bounds.height > 1 else { return }
        let g = naturalGrid(in: sv.bounds.size)
        sendResize(cols: g.cols, rows: g.rows)
    }

    /// Debounced variant for the container's live resize stream.
    func containerDidResize() {
        guard let sv = view.superview, sv.bounds.width > 1, sv.bounds.height > 1 else { return }
        let g = naturalGrid(in: sv.bounds.size)
        guard g.cols >= 2, g.cols <= 1000, g.rows >= 2, g.rows <= 1000 else { return }
        pendingCols = g.cols
        pendingRows = g.rows
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sendResize(cols: self.pendingCols, rows: self.pendingRows)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: TerminalViewDelegate
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        client.send(op: Op.input, pane: lastPane, payload: Array(data))
    }
    private var pendingCols = 0
    private var pendingRows = 0
    private var resizeWork: DispatchWorkItem?
    private var snapshotWork: DispatchWorkItem?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Intentionally NOT an ask: the view's grid now echoes either the pin we
        // applied or the container fill — asks flow from the container's bounds
        // (containerDidResize / sendCurrentGeometry). Echoing the pinned size
        // back as an ask would make a foreign client's size sticky even after
        // that client detaches.
    }

    private func sendResize(cols: Int, rows: Int) {
        guard cols >= 2, cols <= 1000, rows >= 2, rows <= 1000 else { return }
        let p: [UInt8] = [
            UInt8((cols >> 8) & 0xff), UInt8(cols & 0xff),
            UInt8((rows >> 8) & 0xff), UInt8(rows & 0xff),
        ]
        client.send(op: Op.resize, pane: lastPane, payload: p)
    }

    /// One clean repaint shortly after the pin settles. The broker's snapshot is
    /// idempotent (clears screen+scrollback before painting), so this never
    /// duplicates history; capturing AFTER the confirmed reflow is what the old
    /// backed-out on-resize redraw was missing.
    private func scheduleSnapshotRedraw() {
        snapshotWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client.send(op: Op.requestSnapshot, pane: self.lastPane, payload: [])
        }
        snapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) { onScroll?(position) }
    /// Schemes that are universal/network — these open on the Mac, as they should.
    /// Everything else SwiftTerm hands us (bare paths, `file:` URLs) is a path on the
    /// REMOTE host this pane is connected to, so it's routed into that host's Files.
    private static let networkSchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "mailto", "ssh", "sftp", "git",
        "tel", "sms", "facetime", "magnet", "ipfs", "ipns", "gemini", "gopher", "news",
    ]

    func requestOpenLink(source: TerminalView, link rawLink: String, params: [String: String]) {
        // SwiftTerm's implicit-link matcher (Ghostty line map) sometimes hands back
        // the matched text duplicated (e.g. "a/b.mdxa/b.mdx") when its heuristic row
        // group double-counts the line. Collapse an exact doubling first.
        let link = Self.collapseDoubled(rawLink)
        // A real network/web URL.
        if let u = URL(string: link), let scheme = u.scheme?.lowercased(),
           PaneConn.networkSchemes.contains(scheme) {
            // A localhost dashboard URL printed by a session is meaningless on the Mac
            // (the port is on the session's HOST) → open it in the embedded Dashboards
            // window, auto-forwarding if the host is remote.
            if (scheme == "http" || scheme == "https"), let host = u.host?.lowercased(),
               ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) {
                let port = u.port ?? (scheme == "https" ? 443 : 80)
                var path = u.path.isEmpty ? "/" : u.path
                if let q = u.query { path += "?\(q)" }
                onOpenLocalhost?(port, path, scheme)
                return
            }
            // Any other (external) URL is host-independent → open it on the Mac.
            NSWorkspace.shared.open(u)
            return
        }
        // Otherwise it's a filesystem path that lives on THIS pane's host (the Mac
        // can't resolve it). Strip a file:// wrapper + a trailing :line[:col], and
        // hand the path up to be opened in the host's Files window.
        var path = link
        if path.lowercased().hasPrefix("file:") { path = Self.pathFromFileURL(path) }
        let (clean, line) = Self.splitLineSuffix(path)
        onOpenPath?(clean, line)
    }

    /// If `s` is exactly its first half repeated (`X+X`), return `X`; else `s`.
    /// Works around the SwiftTerm implicit-link duplication described above.
    private static func collapseDoubled(_ s: String) -> String {
        let n = s.count
        guard n >= 2, n % 2 == 0 else { return s }
        let mid = s.index(s.startIndex, offsetBy: n / 2)
        return s[..<mid] == s[mid...] ? String(s[..<mid]) : s
    }

    /// `file:///a/b`, `file://host/a/b`, or `file:/a/b` → `/a/b` (host dropped: we
    /// already know which host this pane is on), percent-decoded.
    private static func pathFromFileURL(_ s: String) -> String {
        var r = String(s.dropFirst(5)) // after "file:"
        if r.hasPrefix("//") {
            r = String(r.dropFirst(2))                       // "host/path" or "/path"
            if !r.hasPrefix("/"), let i = r.firstIndex(of: "/") {
                r = String(r[i...])                          // drop the host authority
            }
        }
        return r.removingPercentEncoding ?? r
    }

    /// Splits a trailing `:line` or `:line:col` (compiler / linter / traceback
    /// style) off a path. `foo.py:42:7` → ("foo.py", 42); a plain path → (path, nil).
    private static let lineSuffixRE = try! NSRegularExpression(pattern: #"^(.+?):(\d+)(?::\d+)?$"#)
    private static func splitLineSuffix(_ s: String) -> (path: String, line: Int?) {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = lineSuffixRE.firstMatch(in: s, range: range),
              let pr = Range(m.range(at: 1), in: s),
              let lr = Range(m.range(at: 2), in: s),
              let line = Int(s[lr]) else { return (s, nil) }
        return (String(s[pr]), line)
    }
    func bell(source: TerminalView) {
        switch BellMode(rawValue: UserDefaults.standard.string(forKey: TermPrefs.bellModeKey) ?? TermPrefs.defaultBellMode) ?? .audible {
        case .audible: NSSound.beep()
        case .visual: flashVisualBell()
        case .off: break
        }
    }

    /// A brief screen-flash bell: invert to the foreground tint for ~90ms, then
    /// restore. Uses the view's own native colors so it matches the active theme.
    private func flashVisualBell() {
        guard !bellFlashing else { return }
        bellFlashing = true
        let restore = view.nativeBackgroundColor
        // Lighten the background toward the accent for a clear-but-unobtrusive flash.
        view.nativeBackgroundColor = Theme.nsBellFlash
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self else { return }
            self.view.nativeBackgroundColor = restore
            self.bellFlashing = false
        }
    }
    private var bellFlashing = false
    func clipboardCopy(source: TerminalView, content: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let s = String(data: content, encoding: .utf8) { pb.setString(s, forType: .string) }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

/// The terminal pane's container: flipped so a pinned (letterboxed) terminal
/// anchors to the TOP-left like tmux does, with a resize hook so every hosted
/// view re-frames (pin or fill) and re-asks when the pane area changes.
final class TermContainerView: NSView {
    var onResize: (() -> Void)?
    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onResize?()
    }
}

/// Owns one container NSView and a cache of live PaneConns keyed by session.
/// Showing a session reveals its (warm) view and hides the rest.
final class TerminalController: ObservableObject {
    let container: TermContainerView = {
        let v = TermContainerView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.nsAppBackground.cgColor
        return v
    }()
    private var conns: [String: PaneConn] = [:]
    private var lastShownID: String?

    // MARK: W&B runs — detected per session, shown in-place instead of the terminal
    /// Runs each session advertised (first-seen order; `.last` = latest), keyed by ref.id.
    @Published var wandbRuns: [String: [WandbRun]] = [:]
    /// The run currently shown for a session (defaults to the latest). Keyed by ref.id → runId.
    @Published var wandbCurrent: [String: String] = [:]
    /// Sessions whose detail pane is currently showing the W&B webview (not the terminal).
    @Published var wandbShown: Set<String> = []

    func wandbRuns(for ref: SessionRef) -> [WandbRun] { wandbRuns[ref.id] ?? [] }
    func hasWandb(_ ref: SessionRef) -> Bool { !(wandbRuns[ref.id] ?? []).isEmpty }
    func isWandbShown(_ ref: SessionRef) -> Bool { wandbShown.contains(ref.id) }

    /// The run to display for a session: the user's pick, else the latest detected.
    func currentRun(for ref: SessionRef) -> WandbRun? {
        let runs = wandbRuns[ref.id] ?? []
        if let id = wandbCurrent[ref.id], let r = runs.first(where: { $0.runId == id }) { return r }
        return runs.last
    }

    func setCurrentRun(_ run: WandbRun, for ref: SessionRef) { wandbCurrent[ref.id] = run.runId }

    /// Show the W&B webview for `ref`. With `run`, pin that specific run; without,
    /// default to the LATEST (unless the user already picked one that still exists,
    /// which we keep). No-op if the session has advertised no runs yet.
    func showWandb(_ ref: SessionRef, run: WandbRun? = nil) {
        let runs = wandbRuns[ref.id] ?? []
        if let run {
            wandbCurrent[ref.id] = run.runId                                   // explicit pick
        } else if wandbCurrent[ref.id] == nil || !runs.contains(where: { $0.runId == wandbCurrent[ref.id] }) {
            wandbCurrent[ref.id] = runs.last?.runId                            // default / re-default to latest
        }                                                                       // else: keep the user's earlier pick
        guard currentRun(for: ref) != nil else { return }
        wandbShown.insert(ref.id)
    }
    func hideWandb(_ ref: SessionRef) { wandbShown.remove(ref.id) }
    func toggleWandb(_ ref: SessionRef) {
        if wandbShown.contains(ref.id) { hideWandb(ref) } else { showWandb(ref) }
    }

    // MARK: W&B persistence — a GROWING list that survives buffer-roll AND restarts.
    // Once a run id is discovered it STAYS (union, never replace) — so it doesn't
    // vanish when its URL scrolls out of the ~48KB scan buffer, and it's restored on
    // reopen even if the URL is no longer anywhere in the connect snapshot. Entries
    // age out 7 days after first discovery (pruned on load), or on a manual clear.
    // Keyed by SessionRef.id — the same stable key hidden-panels/path-overrides persist by.
    private let wandbStoreKey = "ut.wandbRuns.v1"
    private static let wandbTTL: TimeInterval = 7 * 24 * 3600

    private func loadWandb() {
        guard let data = UserDefaults.standard.data(forKey: wandbStoreKey),
              let stored = try? JSONDecoder().decode([String: [WandbRun]].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.wandbTTL)
        var kept: [String: [WandbRun]] = [:]
        for (key, runs) in stored {
            // Re-validate with the current rules so already-stored false positives (mangled
            // / truncated ids) disappear without the user having to clear them by hand.
            let fresh = WandbDetector.sanitize(runs.filter { $0.discoveredAt >= cutoff })
            if !fresh.isEmpty { kept[key] = fresh }
        }
        wandbRuns = kept
        persistWandb()   // write the cleaned store back so the migration is permanent
    }

    private func persistWandb() {
        if let data = try? JSONEncoder().encode(wandbRuns) {
            UserDefaults.standard.set(data, forKey: wandbStoreKey)
        }
    }

    /// Fold newly-detected runs into the session's growing list. Appends genuinely-new
    /// ids and upgrades a placeholder label (the bare id) once the run's name is
    /// captured; NEVER drops a run that scrolled out of the buffer. Preserves the
    /// original first-seen time so the 7-day clock isn't reset by re-detection.
    func mergeWandb(_ detected: [WandbRun], for ref: SessionRef) {
        guard !detected.isEmpty else { return }
        var runs = wandbRuns[ref.id] ?? []
        var changed = false
        for d in detected {
            if let i = runs.firstIndex(where: { $0.runId == d.runId }) {
                if runs[i].label == runs[i].runId, d.label != d.runId {   // got a real name now
                    runs[i] = WandbRun(url: runs[i].url, runId: runs[i].runId,
                                       label: d.label, discoveredAt: runs[i].discoveredAt)
                    changed = true
                }
            } else {
                runs.append(d)   // new id — d.discoveredAt == now, starts its 7-day clock
                changed = true
            }
        }
        // Re-validate the merged set: drops cross-scan truncations (a short id seen in one
        // scan next to its full id in another) and is idempotent on already-clean runs.
        if changed { wandbRuns[ref.id] = WandbDetector.sanitize(runs); persistWandb() }
    }

    /// Manually forget ONE detected run for a session (the user's per-run "clear").
    /// Permanent: it only returns if the detector re-sees the URL (a fresh connect
    /// snapshot that still contains it, or the job reprinting it). If the cleared run
    /// was the one being shown, the W&B view re-defaults to the latest remaining run;
    /// clearing the LAST run drops the session out of W&B entirely (back to terminal).
    func clearWandb(_ run: WandbRun, for ref: SessionRef) {
        guard var runs = wandbRuns[ref.id] else { return }
        runs.removeAll { $0.runId == run.runId }
        if runs.isEmpty {
            wandbRuns[ref.id] = nil
            wandbCurrent[ref.id] = nil
            wandbShown.remove(ref.id)
        } else {
            wandbRuns[ref.id] = runs
            if wandbCurrent[ref.id] == run.runId { wandbCurrent[ref.id] = runs.last?.runId }
        }
        persistWandb()
    }

    @Published var fontSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "ut.termFontSize")
        return v >= 8 ? CGFloat(v) : 13.5
    }() {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: "ut.termFontSize")
            applyFont()
        }
    }
    /// Live connection state per session ref id (for the header chip).
    @Published var connState: [String: ConnState] = [:]
    /// Whether the visible terminal is scrolled to the live bottom.
    @Published var atBottom = true
    /// Set by the detail view: routes a terminal-clicked path (+ optional line) to
    /// the Files window for the currently-visible session's host.
    var openPathHandler: ((_ path: String, _ line: Int?) -> Void)?
    /// Set by the detail view: routes a terminal-clicked localhost URL to the
    /// Dashboards window for the currently-visible session's host.
    var openLocalhostHandler: ((_ port: Int, _ path: String, _ scheme: String) -> Void)?

    private var visible: PaneConn? { lastShownID.flatMap { conns[$0] } }

    private var keyMonitor: Any?
    init() {
        loadWandb()   // restore the growing W&B run list (pruning entries >7 days old)
        // Live re-theme: when the user picks a theme, recolor every cached pane IN PLACE
        // (no reconnect, scrollback kept) plus the container background.
        NotificationCenter.default.addObserver(forName: .utThemeChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.container.layer?.backgroundColor = Theme.nsAppBackground.cgColor
            self.conns.values.forEach { $0.applyTheme() }
        }
        // Container resize → every pane re-frames (pinned grid or fill) and
        // re-asks for its natural size from the new bounds.
        container.onResize = { [weak self] in
            guard let self else { return }
            for c in self.conns.values {
                c.applyLayout()
                c.containerDidResize()
            }
        }
        // SwiftTerm's keyDown isn't `open`, so we can't subclass it. A local key
        // monitor (runs before the view sees the key) lets us add: Shift+Enter →
        // newline, and ⌃V of a clipboard image → bridge it to the session's host.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NB: `interceptKey` returns nil to SWALLOW the event — must not `?? event`
            // it, or a consumed key gets handed back to the view and double-fires.
            guard let self else { return event }
            return self.interceptKey(event)
        }
    }
    deinit { if let m = keyMonitor { NSEvent.removeMonitor(m) } }

    /// Returns nil to swallow the event, or the event to let it pass through.
    private func interceptKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The Enter keyDown sometimes fires a hair before the Shift bit lands in the
        // event, so also consult the LIVE modifier state at handler time.
        let live = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shiftDown = mods.contains(.shift) || live.contains(.shift)
        let frView = event.window?.firstResponder as? NSView
        let inTerm = (frView != nil && visible != nil) && frView!.isDescendant(of: visible!.view)
        guard inTerm, let conn = visible else { return event }
        // Shift+Enter → newline (LF), as long as no cmd/ctrl/opt is involved.
        if (event.keyCode == 36 || event.keyCode == 76),
           shiftDown, mods.isDisjoint(with: [.command, .control, .option]) {
            conn.sendInput("\n")   // LF == Ctrl+J == claude/codex "insert newline"
            return nil
        }
        if event.keyCode == 9, mods.contains(.control), mods.isDisjoint(with: [.command, .option]),
           let png = clipboardImagePNG() {   // ⌃V of an image
            conn.handleImagePaste(png)
            return nil
        }
        return event
    }

    // MARK: Find + scroll (operate on the visible terminal)
    @discardableResult func findNext(_ term: String) -> Bool {
        guard !term.isEmpty, let v = visible?.view else { return false }
        return v.findNext(term)
    }
    @discardableResult func findPrev(_ term: String) -> Bool {
        guard !term.isEmpty, let v = visible?.view else { return false }
        return v.findPrevious(term)
    }
    func clearFind() { visible?.view.clearSearch() }

    /// Total case-insensitive matches for `term` across the visible terminal's
    /// whole buffer + scrollback (drives the find bar's match counter). Passing a
    /// huge end row makes getText clamp to the last line, i.e. scan everything.
    func matchCount(_ term: String) -> Int {
        guard !term.isEmpty, let t = visible?.view.getTerminal() else { return 0 }
        let text = t.getText(start: Position(col: 0, row: 0), end: Position(col: t.cols, row: 100_000_000))
        guard !text.isEmpty else { return 0 }
        var count = 0
        var idx = text.startIndex
        while let r = text.range(of: term, options: .caseInsensitive, range: idx..<text.endIndex) {
            count += 1
            idx = r.upperBound
        }
        return count
    }
    func scrollToBottom() { visible?.view.scroll(toPosition: 1.0); atBottom = true }

    /// Text for the Renders panel (⇧⌘P): the user's selection if there is one,
    /// else the recent output (screen + scrollback tail) with soft-wrapped grid
    /// rows rejoined into logical lines, then stripped of TUI chrome.
    func renderableText() -> String? {
        guard let v = visible?.view else { return nil }
        if let sel = v.getSelection(), !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return RenderExtract.clean(sel)
        }
        return RenderExtract.clean(v.getTerminal().getTextJoiningWraps(maxVisualLines: 400))
    }

    /// ⌘V: if the clipboard holds an image, bridge it to the visible session's host;
    /// otherwise do a normal text paste into the terminal.
    func pasteFromClipboard() {
        if let png = clipboardImagePNG(), let conn = visible {
            conn.handleImagePaste(png)
        } else {
            NSApplication.shared.sendAction(Selector(("paste:")), to: nil, from: nil)
        }
    }

    /// Clears the visible terminal's screen + scrollback (Warp-style ⌘K), then
    /// re-applies the theme (reset wipes the palette) and re-sends geometry.
    func clearBuffer() {
        guard let conn = visible else { return }
        let v = conn.view
        v.getTerminal().resetToInitialState()
        v.installColors(Theme.ansi16)
        v.nativeBackgroundColor = Theme.nsAppBackground
        v.nativeForegroundColor = Theme.nsForeground
        v.caretColor = Theme.nsCursor
        // resetToInitialState rebuilds the buffer at the top but fires no scroll event,
        // so the NSScroller keeps its pre-clear knob (stale scrollbar) and the jump-to-
        // bottom pill can stay stuck. Drive `scrolled` manually to force updateScroller()
        // off the now-empty buffer, then re-sync the pill.
        v.scrolled(source: v.getTerminal(), yDisp: 0)
        atBottom = true
        conn.sendCurrentGeometry()
        conn.sendInput("\u{0c}") // Ctrl-L → shell redraws its prompt after the clear
    }

    /// Seamlessly move a live connection from the old session id to the new one
    /// after a rename: the SAME PaneConn (and its still-open socket) is kept, just
    /// re-keyed, so the terminal keeps streaming with no reconnect or screen reload.
    func renameConn(from oldID: String, to newID: String, url: URL) {
        guard oldID != newID, let c = conns[oldID] else { return }
        conns.removeValue(forKey: oldID)
        conns[newID] = c
        c.rename(to: url)
        if let st = connState[oldID] { connState.removeValue(forKey: oldID); connState[newID] = st }
        if lastShownID == oldID { lastShownID = newID }
    }

    /// Tear down a session's warm connection so it does NOT auto-reconnect and
    /// recreate the session after a kill/rename (the broker evicts on /control).
    func drop(_ id: String) {
        if let c = conns[id] {
            c.disconnect()
            c.view.removeFromSuperview()
            conns.removeValue(forKey: id)
        }
        connState.removeValue(forKey: id)
        if lastShownID == id { lastShownID = nil }
    }

    private func currentFont() -> NSFont {
        let family = UserDefaults.standard.string(forKey: TermPrefs.fontFamilyKey) ?? TermPrefs.defaultFontFamily
        return TerminalFonts.font(named: family, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// The user's chosen cursor style (steady variant), defaulting to a block.
    private func currentCursor() -> SwiftTerm.CursorStyle {
        let raw = UserDefaults.standard.string(forKey: TermPrefs.cursorStyleKey) ?? TermPrefs.defaultCursorStyle
        return (CursorPref(rawValue: raw) ?? .block).swiftTerm
    }

    func adjustFont(_ delta: CGFloat) {
        fontSize = max(8, min(36, fontSize + delta))
    }

    func resetFontSize() {
        fontSize = 13.5
    }

    private func applyFont() {
        let f = currentFont()
        for c in conns.values {
            c.setPreferredFont(f) // re-frames the pinned grid (fit-to-pane) + re-asks
        }
    }

    /// Re-apply the persisted font family + cursor style to every live pane.
    /// Called from the Settings pickers (font family / cursor) for a live change.
    func applyAppearance() {
        let f = currentFont()
        let cursor = currentCursor()
        for c in conns.values {
            c.view.getTerminal().setCursorStyle(cursor)
            c.styleScroller()
            c.setPreferredFont(f) // re-frames the pinned grid (fit-to-pane) + re-asks
        }
    }

    func show(ref: SessionRef?, url: URL?) {
        guard let ref, let url else {
            for (_, c) in conns { c.view.isHidden = true }
            lastShownID = nil
            return
        }
        let conn: PaneConn
        if let existing = conns[ref.id] {
            conn = existing
            // A pane is keyed by session NAME, but the URL carries the stable tmux id
            // ($N), which changes when the session is re-created under the same name —
            // e.g. resumed from history. The parent recomputes wsURL on every update,
            // so adopt a changed URL here; BrokerClient then dials the new id (and, if
            // it was stuck reconnecting on the dead old id, reconnects at once).
            if existing.connURL != url { existing.rename(to: url) }
        } else {
            conn = PaneConn(url: url)
            conn.onOpenPath = { [weak self] path, line in self?.openPathHandler?(path, line) }
            conn.onOpenLocalhost = { [weak self] port, path, scheme in self?.openLocalhostHandler?(port, path, scheme) }
            conn.onState = { [weak self] st in self?.connState[ref.id] = st }
            conn.onWandbRuns = { [weak self] runs in self?.mergeWandb(runs, for: ref) }
            conn.onScroll = { [weak self] pos in
                guard let self, ref.id == self.lastShownID else { return }
                let bottom = pos >= 0.999
                if bottom != self.atBottom { self.atBottom = bottom }
            }
            conn.setPreferredFont(currentFont())
            // No autoresizing: frames are managed by applyLayout (pinned grid or
            // container fill) from the container's resize hook.
            conn.view.autoresizingMask = []
            container.addSubview(conn.view)
            conn.applyLayout()
            conns[ref.id] = conn
        }
        for (id, c) in conns { c.view.isHidden = (id != ref.id) }

        // Only do the expensive work (refocus, geometry push) on an ACTUAL
        // selection change — updateNSView fires on every SwiftUI invalidation,
        // and refocusing each time steals the keyboard from the filter field.
        guard lastShownID != ref.id else { return }
        lastShownID = ref.id
        conn.applyLayout()
        conn.view.layoutSubtreeIfNeeded()
        conn.sendCurrentGeometry()
        // Switching panes ALWAYS hands the keyboard to that pane's terminal —
        // even from the sidebar filter (an NSText): picking a session IS the
        // end of filtering. The lastShownID guard above already prevents the
        // repeated-updateNSView focus theft this used to defend against.
        // NOTE: `atBottom` (a @Published read by the scroll-to-bottom pill) is
        // deferred to the next runloop on purpose. show() runs INSIDE
        // TerminalHostView.updateNSView (the SwiftUI update phase); writing an
        // observed property there is a write-during-update → AttributeGraph
        // cycle that froze sidebar rows. Off the update tick, it's a clean write.
        DispatchQueue.main.async {
            self.atBottom = true
            conn.view.window?.makeFirstResponder(conn.view)
        }
    }

    /// Hand the keyboard back to the visible terminal — used by overlays
    /// (find, palette, render) when they dismiss, so focus never strands on
    /// whatever AppKit picks next (usually the sidebar filter).
    func focusTerminal() {
        guard let v = visible?.view else { return }
        DispatchQueue.main.async {
            v.window?.makeFirstResponder(v)
        }
    }
}

/// SwiftUI bridge: shows the controller's container; updates which session is visible.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController
    let ref: SessionRef?
    let url: URL?

    func makeNSView(context: Context) -> NSView { controller.container }
    func updateNSView(_ nsView: NSView, context: Context) {
        controller.show(ref: ref, url: url)
    }
}

/// A PNG of the current clipboard image, or nil if the clipboard isn't an image.
/// (Screenshots usually land on the pasteboard as TIFF, so convert when needed.)
func clipboardImagePNG() -> Data? {
    let pb = NSPasteboard.general
    if let png = pb.data(forType: .png) { return png }
    if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
        return rep.representation(using: .png, properties: [:])
    }
    if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff) {
        return rep.representation(using: .png, properties: [:])
    }
    return nil
}
