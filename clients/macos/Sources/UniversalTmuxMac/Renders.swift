import AppKit
import SwiftUI
import WebKit

// MARK: - "Renders": render the terminal's markdown/LaTeX/code properly (⇧⌘P)
//
// Agents emit markdown with math and fenced code, which a cell grid can't
// typeset. Rendering IN PLACE would fight the remote TUI (the pane owns its
// cells; any redraw/snapshot would wipe local edits), so this is a Quick-Look
// style overlay instead: one keystroke renders a STATIC SNAPSHOT of the
// terminal text (selection if any, else recent output) in a webview hosting an
// offline bundle (marked + KaTeX + highlight.js — Resources/render), Esc
// dismisses, the live terminal underneath is never touched.

enum RenderExtract {
    /// Lines that are pure TUI decoration (box-drawing borders, rules, blanks
    /// between them). Kept deliberately dumb and deterministic: stray glyphs in
    /// a render cost one Esc keypress; clever heuristics cost trust.
    private static let chromeOnly: CharacterSet = {
        var s = CharacterSet.whitespaces
        s.insert(charactersIn: "─━│┃┄┅┆┇┈┉┊┋┌┍┎┏┐┑┒┓└┕┖┗┘┙┚┛├┝┞┟┠┡┢┣┤┥┦┧┨┩┪┫┬┭┮┯┰┱┲┳┴┵┶┷┸┹┺┻┼╌╍╎╏═║╒╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡╢╣╤╥╦╧╨╩╪╫╬╭╮╯╰╱╲╳▔▁▏▕")
        return s
    }()

    /// Per-line leading gutters agents draw before content (claude's `⏺` turn
    /// marker, `⎿` tool-result elbow, `│`/`┃` quote bars/box edges).
    private static let gutterPrefixes = ["⏺ ", "⎿ ", "│ ", "┃ ", "▌ ", "▐ "]

    /// Strip TUI chrome from extracted terminal text, preserving everything else
    /// verbatim (markdown indentation matters — only KNOWN gutters are removed).
    static func clean(_ raw: String) -> String {
        var out: [String] = []
        for var line in raw.components(separatedBy: "\n") {
            // Drop decoration-only lines (pane borders, rules).
            if !line.isEmpty, line.unicodeScalars.allSatisfy({ chromeOnly.contains($0) }) {
                continue
            }
            // Peel leading gutters (possibly nested, e.g. "│ ⏺ text"), each
            // optionally preceded by indentation.
            var peeled = true
            while peeled {
                peeled = false
                let ws = line.prefix(while: { $0 == " " })
                let body = line.dropFirst(ws.count)
                for g in gutterPrefixes where body.hasPrefix(g) {
                    line = String(body.dropFirst(g.count))
                    peeled = true
                    break
                }
                // A bare trailing gutter char (empty content after it).
                if !peeled, gutterPrefixes.map({ String($0.first!) }).contains(String(body)) {
                    line = ""
                    peeled = true
                }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

/// The overlay panel: header (source hint, zoom, close) + the render webview.
/// Esc and ⌘+/−/0 are handled by a local key monitor while the panel is up.
struct RenderPanel: View {
    @EnvironmentObject var state: AppState
    let text: String

    @AppStorage("ut.renderFontSize") private var fontSize = 14.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    Text("Render").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("markdown · LaTeX · code").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    HStack(spacing: 2) {
                        zoomButton("minus") { adjustZoom(-1) }
                        Text("\(Int(fontSize))").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary).frame(width: 22)
                        zoomButton("plus") { adjustZoom(1) }
                    }
                    Button { close() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                }
                .padding(.horizontal, 14).frame(height: 40)
                Rectangle().fill(Theme.border).frame(height: 1)
                RenderWebView(markdown: text, fontSize: fontSize)
            }
            .frame(minWidth: 480, idealWidth: 760, maxWidth: 900)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 36)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: "#0D0E12"))
                    .padding(.vertical, 36)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                    .padding(.vertical, 36)
            )
            .shadow(color: .black.opacity(0.45), radius: 26, y: 10)
        }
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
    }

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func adjustZoom(_ d: Double) { fontSize = min(28, max(9, fontSize + d)) }
    private func close() { state.renderText = nil }

    // Esc closes; ⌘+/−/0 zoom the rendered content (standing requirement: every
    // content pane gets keyboard zoom) without reaching the terminal behind.
    @State private var monitor: Any?
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { close(); return nil } // Esc
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command {
                switch e.charactersIgnoringModifiers {
                case "=", "+": adjustZoom(1); return nil
                case "-": adjustZoom(-1); return nil
                case "0": fontSize = 14; return nil
                default: break
                }
            }
            return e
        }
    }
    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

/// WKWebView hosting the offline render bundle (Resources/render). The text is
/// a static snapshot pushed once on load; zoom updates restyle in place.
private struct RenderWebView: NSViewRepresentable {
    let markdown: String
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.navigationDelegate = context.coordinator
        if #available(macOS 12.0, *) { wv.underPageBackgroundColor = NSColor(red: 0.051, green: 0.055, blue: 0.071, alpha: 1) }
        wv.setValue(false, forKey: "drawsBackground")   // no white flash while loading
        context.coordinator.pending = (markdown, fontSize)
        let dir = Bundle.main.resourceURL!.appendingPathComponent("render")
        wv.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.update(wv, markdown, fontSize)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var pending: (String, Double)?
        private var ready = false
        private var shownText: String?
        private var shownSize: Double = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let p = pending { push(webView, p.0, p.1); pending = nil }
        }
        func update(_ wv: WKWebView, _ text: String, _ size: Double) {
            guard ready else { pending = (text, size); return }
            if shownText != text { push(wv, text, size) }
            else if shownSize != size {
                shownSize = size
                wv.evaluateJavaScript("window.UTRender.setZoom(\(Int(size)))")
            }
        }
        private func push(_ wv: WKWebView, _ text: String, _ size: Double) {
            shownText = text
            shownSize = size
            wv.evaluateJavaScript("window.UTRender.set(\(js(text)), \(Int(size)))")
        }
        private func js(_ s: String) -> String {
            guard let d = try? JSONSerialization.data(withJSONObject: [s]),
                  let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
            return String(arr.dropFirst().dropLast())
        }
    }
}
