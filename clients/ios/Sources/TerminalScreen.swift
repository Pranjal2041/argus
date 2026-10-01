import SafariServices
import SwiftTerm
import SwiftUI
import UIKit
import WebKit

/// Hosts a SwiftTerm view pinned to the broker's authoritative grid. tmux output
/// is formatted for exactly PANE_SIZE cols×rows, so the emulator is sized to
/// that grid (largest font that fits, letterboxed) rather than to the screen.
final class PinnedTerminalContainer: UIView, TerminalViewDelegate {
    let terminal = TerminalView(frame: .zero)
    let connection: TerminalConnection
    var journal: UtteranceRecorder?
    var onOutputScan: ((ArraySlice<UInt8>) -> Void)?
    private var pane: (cols: Int, rows: Int)?
    /// Font used to compute the grid this phone asks for.
    static let preferredFontSize: CGFloat = 12
    static let minFontSize: CGFloat = 5

    init(connection: TerminalConnection) {
        self.connection = connection
        super.init(frame: .zero)
        terminal.terminalDelegate = self
        terminal.getTerminal().changeScrollback(10_000)
        terminal.font = Self.font(Self.preferredFontSize)
        addSubview(terminal)
        connection.onOutput = { [weak self] bytes in
            self?.terminal.feed(byteArray: bytes)
            self?.onOutputScan?(bytes)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ p: ThemePalette) {
        backgroundColor = ThemePalette.uiColor(p.termBg)
        terminal.backgroundColor = ThemePalette.uiColor(p.termBg)
        terminal.nativeBackgroundColor = ThemePalette.uiColor(p.termBg)
        terminal.nativeForegroundColor = ThemePalette.uiColor(p.termFg)
        terminal.caretColor = ThemePalette.uiColor(p.termCursor)
        terminal.installColors(p.ansi.map { hex in
            SwiftTerm.Color(red: UInt16((hex >> 16) & 0xff) * 257, green: UInt16((hex >> 8) & 0xff) * 257,
                            blue: UInt16(hex & 0xff) * 257)
        })
    }

    static func font(_ size: CGFloat) -> UIFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    /// Same metrics SwiftTerm uses: advance of a glyph, ceil(ascent+descent+leading).
    static func cell(_ font: UIFont) -> CGSize {
        let ct = font as CTFont
        var glyph = CTFontGetGlyphWithName(ct, "W" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
        let height = ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
        return CGSize(width: advance.width, height: height)
    }

    func setPane(cols: Int, rows: Int) {
        if let p = pane, p.cols == cols, p.rows == rows { return }
        pane = (cols, rows)
        setNeedsLayout()
    }

    /// The last visible lines, as text (journal context).
    func screenTail(_ n: Int = 60) -> [String] {
        let t = terminal.getTerminal()
        return (0..<t.rows).compactMap { t.getLine(row: $0)?.translateToString(trimRight: true) }
            .reversed().drop { $0.isEmpty }.reversed().suffix(n)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let avail = bounds.inset(by: safeAreaInsets)
        guard avail.width > 20, avail.height > 20 else { return }

        // Ask for the grid this screen shows comfortably at the preferred font.
        let preferred = Self.cell(Self.font(Self.preferredFontSize))
        connection.requestSize(cols: Int(avail.width / preferred.width), rows: Int(avail.height / preferred.height))

        // Pin to the broker's grid: the largest font (≤ preferred) that fits it.
        guard let pane else { terminal.frame = avail; return }
        var size = Self.preferredFontSize
        var cell = preferred
        while size > Self.minFontSize,
              CGFloat(pane.cols) * cell.width > avail.width || CGFloat(pane.rows) * cell.height > avail.height {
            size -= 0.25
            cell = Self.cell(Self.font(size))
        }
        if terminal.font.pointSize != size { terminal.font = Self.font(size) }
        // A hair over cols×cell so SwiftTerm's floor() lands exactly on the grid.
        let w = CGFloat(pane.cols) * cell.width + 0.5
        let h = CGFloat(pane.rows) * cell.height + 0.5
        terminal.frame = CGRect(x: avail.minX + max(0, (avail.width - w) / 2), y: avail.minY,
                                width: min(w, avail.width), height: min(h, avail.height))
        let t = terminal.getTerminal()
        if t.cols != pane.cols || t.rows != pane.rows { t.resize(cols: pane.cols, rows: pane.rows) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        Task { @MainActor in
            connection.send(data)
            journal?.feed(data)
        }
    }
    // The pinned grid is the broker's; local geometry changes never become requests.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Owns the UIKit container so screen actions (find, render) can reach it.
@MainActor
final class TerminalHandle: ObservableObject {
    weak var container: PinnedTerminalContainer?
    @Published var wandbRuns: [WandbRun] = []
    private var scanBuffer = ""
    private var scanTask: Task<Void, Never>?

    /// W&B detection over raw output, debounced; keeps a tail so a URL split
    /// across chunks rejoins (as Android does).
    func scan(_ bytes: ArraySlice<UInt8>, key: String) {
        scanBuffer += String(decoding: bytes, as: UTF8.self)
        let immediate = scanBuffer.utf8.count > 512 * 1024
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard let self, !Task.isCancelled else { return }
            let found = WandbDetector.runs(in: self.scanBuffer)
            self.scanBuffer = String(self.scanBuffer.suffix(8192))
            guard !found.isEmpty else { return }
            self.wandbRuns = WandbStore.merge(found, key: key)
        }
    }
}

struct TerminalRepresentable: UIViewRepresentable {
    @ObservedObject var connection: TerminalConnection
    let handle: TerminalHandle
    let palette: ThemePalette
    let journalKey: (Machine, String)
    let wandbKey: String

    func makeUIView(context: Context) -> PinnedTerminalContainer {
        let v = PinnedTerminalContainer(connection: connection)
        v.apply(palette)
        handle.container = v
        v.journal = JournalCapture.shared.recorder(machine: journalKey.0, session: journalKey.1) { [weak v] in v?.screenTail() ?? [] }
        v.onOutputScan = { [weak handle] bytes in Task { @MainActor in handle?.scan(bytes, key: wandbKey) } }
        DispatchQueue.main.async { _ = v.terminal.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ v: PinnedTerminalContainer, context: Context) {
        if let p = connection.paneSize { v.setPane(cols: p.cols, rows: p.rows) }
        v.apply(palette)
    }

    static func dismantleUIView(_ v: PinnedTerminalContainer, coordinator: ()) { v.journal?.finish() }
}

struct TerminalScreen: View {
    let machine: Machine
    let session: SessionInfo
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var theme: ThemeStore
    @StateObject private var connection: TerminalConnection
    @StateObject private var handle = TerminalHandle()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var finding = false
    @State private var findText = ""
    @State private var findMissed = false
    @State private var rendering = false
    @State private var wandbURL: URL?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmKill = false
    @State private var actionError: String?

    init(machine: Machine, session: SessionInfo) {
        self.machine = machine
        self.session = session
        _connection = StateObject(wrappedValue: TerminalConnection(machine: machine, handle: session.handle))
    }

    private var key: String { FleetStore.key(machine, session) }

    var body: some View {
        VStack(spacing: 0) {
            if finding { findBar }
            TerminalRepresentable(connection: connection, handle: handle, palette: theme.palette,
                                  journalKey: (machine, session.name), wandbKey: key)
                .overlay(alignment: .top) {
                    if connection.state == .reconnecting || connection.state == .connecting {
                        Button { connection.connect() } label: {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(connection.state == .connecting ? "Connecting…" : "Reconnecting… tap to retry")
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: connection.state)
        }
        .background(ThemePalette.color(theme.palette.termBg))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(session.name).font(.headline)
                    Text(statusText).font(.caption2).foregroundStyle(connection.state == .connected ? Color.secondary : Color.orange)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !handle.wandbRuns.isEmpty {
                    Menu {
                        ForEach(handle.wandbRuns) { r in Button(r.label) { wandbURL = r.url } }
                    } label: { Image(systemName: "chart.xyaxis.line") }
                }
                Button { rendering = true } label: { Image(systemName: "doc.richtext") }.accessibilityLabel("Render output")
                menu
            }
        }
        .onAppear {
            connection.connect()
            fleet.acknowledge(machine, session)
            AttentionNotifications.shared.visibleSessionKey = key
            AttentionNotifications.shared.clearSession(machine, session)
            handle.wandbRuns = WandbStore.runs(key: key)
        }
        .onDisappear {
            connection.close()
            if AttentionNotifications.shared.visibleSessionKey == key { AttentionNotifications.shared.visibleSessionKey = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends sockets in the background; resume with a fresh attach.
            if phase == .active, connection.state != .connected { connection.connect() }
        }
        .sheet(isPresented: $rendering) { RenderOutputView(machine: machine, session: session, handle: handle) }
        .sheet(item: $wandbURL) { SafariView(url: $0).ignoresSafeArea() }
        .alert("Rename session", isPresented: $renaming) {
            TextField("name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") { act { try await fleet.renameSession(session, on: machine, to: newName); dismiss() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Kill \(session.name)?", isPresented: $confirmKill, titleVisibility: .visible) {
            Button("Kill session", role: .destructive) { act { try await fleet.killSession(session, on: machine); dismiss() } }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private var menu: some View {
        Menu {
            Button { finding.toggle(); findMissed = false } label: { Label("Find", systemImage: "magnifyingglass") }
            if let path = session.path, !path.isEmpty {
                Button { router.openFiles(machine, path: path) } label: { Label("Open folder in Files", systemImage: "folder") }
            }
            Button { connection.requestSnapshot() } label: { Label("Repaint", systemImage: "arrow.clockwise") }
            Menu {
                ForEach(FleetStore.statusLabels, id: \.label) { s in
                    Button(s.title) { act { try await fleet.setStatus(s.label, for: session, on: machine) } }
                }
            } label: { Label("Set status", systemImage: "flag") }
            Button { fleet.toggleBacklog(machine, session) } label: {
                Label(fleet.backlog.contains(key) ? "Remove from backlog" : "Backlog — set aside", systemImage: "tray")
            }
            Divider()
            Button { newName = session.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            Button { act { try await fleet.setHidden(session, on: machine, hidden: !session.hidden); dismiss() } } label: {
                Label(session.hidden ? "Unhide" : "Hide", systemImage: session.hidden ? "eye" : "eye.slash")
            }
            Button(role: .destructive) { confirmKill = true } label: { Label("Kill", systemImage: "xmark.octagon") }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in scrollback", text: $findText)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { find(forward: false) }
                .onChange(of: findText) { _, _ in find(forward: false) }
            if findMissed { Text("0").foregroundStyle(.orange).font(.caption) }
            Button { find(forward: false) } label: { Image(systemName: "chevron.up") }
            Button { find(forward: true) } label: { Image(systemName: "chevron.down") }
            Button { finding = false; findText = "" } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    /// Newest-first like Android: the first search lands on the latest match.
    private func find(forward: Bool) {
        guard let t = handle.container?.terminal, !findText.isEmpty else { findMissed = false; return }
        var options = SearchOptions()
        options.caseSensitive = false
        findMissed = !(forward ? t.findNext(findText, options: options) : t.findPrevious(findText, options: options))
    }

    private func act(_ body: @escaping () async throws -> Void) {
        Task { do { try await body() } catch { actionError = error.localizedDescription } }
    }

    private var statusText: String {
        switch connection.state {
        case .connecting: return "connecting to \(machine.name)…"
        case .connected:
            if let p = connection.paneSize { return "\(machine.name) · \(p.cols)×\(p.rows)" }
            return machine.name
        case .reconnecting: return "reconnecting…"
        case .closed: return "closed"
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_: SFSafariViewController, context: Context) {}
}

// MARK: Render Output

/// The agent's own transcript (`/render-source`, Markdown) when the broker has
/// one, else the terminal's text — rendered with the bundled offline renderer
/// (Markdown, LaTeX, tables, code) shared with the Android client.
struct RenderOutputView: View {
    let machine: Machine
    let session: SessionInfo
    let handle: TerminalHandle
    @Environment(\.dismiss) private var dismiss
    @State private var markdown: String?
    @State private var origin = "terminal"
    @State private var fontSize: CGFloat = 16
    /// Terminal fallback only: show raw text instead of interpreting Markdown
    /// (plain shell output like `ls` isn't Markdown).
    @State private var plain = false

    private struct Source: Decodable { let source: String?; let format: String?; let origin: String? }

    var body: some View {
        NavigationStack {
            Group {
                if let markdown {
                    RenderWebView(markdown: plain ? "```text\n" + markdown + "\n```" : markdown, fontSize: fontSize)
                } else { ProgressView() }
            }
            .navigationTitle("Rendered output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(session.name).font(.headline)
                        Text(origin.hasSuffix("-transcript") ? "Markdown · LaTeX · tables · code" : "rendered terminal fallback")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !origin.hasSuffix("-transcript") {
                        Button { plain.toggle() } label: { Image(systemName: plain ? "doc.richtext" : "text.alignleft") }
                            .accessibilityLabel(plain ? "Render as Markdown" : "Show plain text")
                    }
                    Button { fontSize = max(9, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                    Button { fontSize = min(28, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                    if let markdown { ShareLink(item: markdown) }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        markdown = Self.terminalText(handle)
        guard let (data, resp) = try? await BrokerHTTP.raw("GET", machine.httpBase, "render-source",
                                                           query: [.init(name: "session", value: session.name)]),
              resp.statusCode == 200, let s = try? JSONDecoder().decode(Source.self, from: data),
              let source = s.source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              s.format == "markdown" else { return }
        markdown = source
        origin = s.origin ?? "transcript"
    }

    /// Terminal text with soft wraps rejoined and agent gutters removed.
    static func terminalText(_ handle: TerminalHandle) -> String {
        guard let t = handle.container?.terminal.getTerminal() else { return "" }
        return t.getTextJoiningWraps(maxVisualLines: 400)
            .replacingOccurrences(of: "\u{0}", with: " ")
            .components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.drop { $0 == " " }
                for gutter in ["⏺ ", "⎿ "] where trimmed.hasPrefix(gutter) { return String(trimmed.dropFirst(gutter.count)) }
                return line
            }
            .joined(separator: "\n")
    }
}

struct RenderWebView: UIViewRepresentable {
    let markdown: String
    let fontSize: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "render") {
            web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.pending = (markdown, fontSize)
        context.coordinator.push(web)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false
        var pending: (String, CGFloat)?
        func webView(_ web: WKWebView, didFinish _: WKNavigation!) { loaded = true; push(web) }
        func push(_ web: WKWebView) {
            guard loaded, let (md, px) = pending,
                  let json = try? JSONSerialization.data(withJSONObject: [md]),
                  let arg = String(data: json, encoding: .utf8) else { return }
            web.evaluateJavaScript("window.UTRender.set(\(arg)[0], \(Int(px)))")
        }
    }
}
