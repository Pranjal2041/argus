import SwiftTerm
import SwiftUI
import UIKit

/// Hosts a SwiftTerm view pinned to the broker's authoritative grid. tmux output
/// is formatted for exactly PANE_SIZE cols×rows, so the emulator is sized to
/// that grid (largest font that fits, letterboxed) rather than to the screen.
final class PinnedTerminalContainer: UIView, TerminalViewDelegate {
    let terminal = TerminalView(frame: .zero)
    let connection: TerminalConnection
    private var pane: (cols: Int, rows: Int)?
    /// Font used to compute the grid this phone asks for.
    static let preferredFontSize: CGFloat = 12
    static let minFontSize: CGFloat = 5

    init(connection: TerminalConnection) {
        self.connection = connection
        super.init(frame: .zero)
        backgroundColor = .black
        terminal.terminalDelegate = self
        terminal.backgroundColor = .black
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        terminal.font = Self.font(Self.preferredFontSize)
        terminal.getTerminal().changeScrollback(10_000)
        addSubview(terminal)
        connection.onOutput = { [weak self] bytes in self?.terminal.feed(byteArray: bytes) }
    }

    required init?(coder: NSCoder) { fatalError() }

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
        pane = (cols, rows)
        setNeedsLayout()
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
        Task { @MainActor in connection.send(data) }
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

struct TerminalRepresentable: UIViewRepresentable {
    @ObservedObject var connection: TerminalConnection

    func makeUIView(context: Context) -> PinnedTerminalContainer {
        let v = PinnedTerminalContainer(connection: connection)
        DispatchQueue.main.async { _ = v.terminal.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ v: PinnedTerminalContainer, context: Context) {
        if let p = connection.paneSize { v.setPane(cols: p.cols, rows: p.rows) }
    }
}

struct TerminalScreen: View {
    let machine: Machine
    let session: SessionInfo
    @StateObject private var connection: TerminalConnection
    @Environment(\.scenePhase) private var scenePhase

    init(machine: Machine, session: SessionInfo) {
        self.machine = machine
        self.session = session
        _connection = StateObject(wrappedValue: TerminalConnection(machine: machine, handle: session.handle))
    }

    var body: some View {
        TerminalRepresentable(connection: connection)
            .background(Color.black)
            .navigationTitle(session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(session.name).font(.headline)
                        Text(statusText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { connection.requestSnapshot() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Repaint")
                }
            }
            .onAppear { connection.connect() }
            .onDisappear { connection.close() }
            .onChange(of: scenePhase) { _, phase in
                // iOS suspends sockets in the background; resume with a fresh attach.
                if phase == .active, connection.state != .connected { connection.connect() }
            }
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
