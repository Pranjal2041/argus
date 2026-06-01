import AppKit
import SwiftTerm
import SwiftUI

/// One live terminal: a SwiftTerm view + its broker connection + delegate.
/// Kept alive for the lifetime of the app session so switching away and back
/// preserves scrollback and the connection (no reconnect, no reload).
final class PaneConn: NSObject, TerminalViewDelegate {
    let view: TerminalView
    private let client: BrokerClient
    private var lastPane = ""

    /// Forwarded live connection state (for the header status chip).
    var onState: ((ConnState) -> Void)?
    /// Forwarded scroll position (0=top … 1=bottom) for the jump-to-bottom pill.
    var onScroll: ((Double) -> Void)?
    /// A clicked file PATH (not a web URL) on this pane's host, with an optional
    /// line number — routed to the host's Files window instead of the local Mac.
    var onOpenPath: ((_ path: String, _ line: Int?) -> Void)?

    init(url: URL) {
        view = TerminalView(frame: .zero)
        client = BrokerClient(url: url)
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
        // Seamless theme: terminal background == window background (no seam on
        // switch), Tokyo-Night-ish 16-color ANSI, periwinkle caret.
        view.installColors(Theme.ansi16)
        view.nativeBackgroundColor = Theme.nsAppBackground
        view.nativeForegroundColor = Theme.nsForeground
        view.caretColor = Theme.nsCursor
        view.caretTextColor = Theme.nsCursorText
        view.selectedTextBackgroundColor = Theme.nsSelection
        client.onOutput = { [weak self] bytes in
            DispatchQueue.main.async { self?.view.feed(byteArray: bytes[...]) }
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

    /// Repoint this live connection at the renamed session's URL. The open socket
    /// is left untouched (the broker keeps streaming across the rename); only a
    /// future reconnect uses the new URL.
    func rename(to newURL: URL) { client.updateURL(newURL) }

    /// Send raw input to this pane's active pane (op=input, empty pane id).
    func sendInput(_ text: String) {
        client.send(op: Op.input, pane: lastPane, payload: Array(text.utf8))
    }

    /// Style the enclosing scroller to an unobtrusive dark overlay (best-effort).
    func styleScroller() {
        if let sv = view.enclosingScrollView {
            sv.scrollerStyle = .overlay
            sv.scrollerKnobStyle = .light
            sv.hasVerticalScroller = true
        }
    }

    /// Read the terminal's current grid and send it immediately (non-debounced).
    /// Called on connect and on show() so a freshly attached session reflows.
    ///
    /// Gated on a real, laid-out frame: a zero/degenerate frame makes SwiftTerm
    /// report a 2-column floor, and that bogus size — as the broker's FIRST resize
    /// — would prime the snapshot at 2 columns wide (the blank/garbled new pane).
    /// When the frame isn't ready, the debounced `sizeChanged` (which fires once
    /// layout settles) sends the first real geometry instead.
    func sendCurrentGeometry() {
        guard view.frame.width > 1, view.frame.height > 1 else { return }
        let t = view.getTerminal()
        guard t.cols > 2, t.rows > 2 else { return }
        sendResize(cols: t.cols, rows: t.rows)
    }

    // MARK: TerminalViewDelegate
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        client.send(op: Op.input, pane: lastPane, payload: Array(data))
    }
    private var pendingCols = 0
    private var pendingRows = 0
    private var resizeWork: DispatchWorkItem?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm emits transient/degenerate sizes during layout (e.g. 2x1,
        // -2x0, or huge values before font metrics settle). Reject the absurd
        // ones and debounce, so tmux only ever receives the final valid size —
        // a bogus size makes tmux render onto nonsense lines (garbled output).
        guard newCols >= 2, newCols <= 1000, newRows >= 2, newRows <= 1000 else { return }
        pendingCols = newCols
        pendingRows = newRows
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sendResize(cols: self.pendingCols, rows: self.pendingRows)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func sendResize(cols: Int, rows: Int) {
        guard cols >= 2, cols <= 1000, rows >= 2, rows <= 1000 else { return }
        let p: [UInt8] = [
            UInt8((cols >> 8) & 0xff), UInt8(cols & 0xff),
            UInt8((rows >> 8) & 0xff), UInt8(rows & 0xff),
        ]
        client.send(op: Op.resize, pane: lastPane, payload: p)
    }

    // NOTE: on-resize snapshot redraw (opReqSnapshot) was backed out — injecting a
    // captured full-screen snapshot into a LIVE stream interleaves with the agent's
    // ongoing output and leaves residual characters (a captured copy wedged between
    // the live cells). A correct resize redraw needs the broker to capture only
    // AFTER tmux confirms the new width (deterministic reflow-sync), not a timed
    // guess mid-stream. Until then we keep the safe geometry-gating above and the
    // broker's one-shot connect snapshot. The broker's opReqSnapshot handler simply
    // goes unused.

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
        // A real network/web URL is host-independent → open it locally on the Mac.
        if let u = URL(string: link), let scheme = u.scheme?.lowercased(),
           PaneConn.networkSchemes.contains(scheme) {
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

/// Owns one container NSView and a cache of live PaneConns keyed by session.
/// Showing a session reveals its (warm) view and hides the rest.
final class TerminalController: ObservableObject {
    let container: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.nsAppBackground.cgColor
        return v
    }()
    private var conns: [String: PaneConn] = [:]
    private var lastShownID: String?
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

    private var visible: PaneConn? { lastShownID.flatMap { conns[$0] } }

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
        for c in conns.values { c.view.font = f }
    }

    /// Re-apply the persisted font family + cursor style to every live pane.
    /// Called from the Settings pickers (font family / cursor) for a live change.
    func applyAppearance() {
        let f = currentFont()
        let cursor = currentCursor()
        for c in conns.values {
            c.view.font = f
            c.view.getTerminal().setCursorStyle(cursor)
            c.styleScroller()
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
        } else {
            conn = PaneConn(url: url)
            conn.onOpenPath = { [weak self] path, line in self?.openPathHandler?(path, line) }
            conn.onState = { [weak self] st in self?.connState[ref.id] = st }
            conn.onScroll = { [weak self] pos in
                guard let self, ref.id == self.lastShownID else { return }
                let bottom = pos >= 0.999
                if bottom != self.atBottom { self.atBottom = bottom }
            }
            conn.view.font = currentFont()
            conn.view.autoresizingMask = [.width, .height]
            container.addSubview(conn.view)
            conns[ref.id] = conn
        }
        for (id, c) in conns { c.view.isHidden = (id != ref.id) }

        // Only do the expensive work (refocus, geometry push) on an ACTUAL
        // selection change — updateNSView fires on every SwiftUI invalidation,
        // and refocusing each time steals the keyboard from the filter field.
        guard lastShownID != ref.id else { return }
        lastShownID = ref.id
        atBottom = true
        conn.view.frame = container.bounds
        conn.view.layoutSubtreeIfNeeded()
        conn.sendCurrentGeometry()
        DispatchQueue.main.async {
            guard let w = conn.view.window else { return }
            if !(w.firstResponder is NSText) { w.makeFirstResponder(conn.view) }
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
