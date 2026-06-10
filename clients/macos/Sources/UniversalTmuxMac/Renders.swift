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
    /// Per-line leading gutters that are unambiguously AGENT chrome (claude's
    /// `⏺` turn marker and `⎿` tool-result elbow). Box-drawing characters are
    /// deliberately NOT touched here anymore: they may be content the terminal
    /// already typeset (tables, rules) — the renderer's segmenter preserves
    /// those runs verbatim instead. Stripping them destroyed real tables.
    private static let gutterPrefixes = ["⏺ ", "⎿ "]

    /// Strip agent chrome from extracted terminal text, preserving everything
    /// else verbatim (markdown indentation matters — only KNOWN gutters go).
    static func clean(_ raw: String) -> String {
        // Never-written terminal cells extract as literal U+0000, which HTML
        // silently drops — gluing words together. Belt-and-braces here (the
        // buffer extractor already maps them) because the SELECTION path goes
        // through SwiftTerm's own machinery, which does not.
        let raw = raw.replacingOccurrences(of: "\u{0}", with: " ")
        var out: [String] = []
        for var line in raw.components(separatedBy: "\n") {
            let ws = line.prefix(while: { $0 == " " })
            let body = line.dropFirst(ws.count)
            for g in gutterPrefixes where body.hasPrefix(g) {
                line = String(body.dropFirst(g.count))
                break
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

/// Bridge for panel-header actions that must reach the hosted WKWebView
/// (PDF export needs the live web view, not SwiftUI state).
final class RenderWebProxy: ObservableObject {
    weak var webView: WKWebView?

    /// Snapshot the FULL rendered document (not just the viewport) into a
    /// one-page PDF via WebKit's native renderer, then ask where to save it.
    func exportPDF(suggestedName: String) {
        guard let wv = webView else { return }
        wv.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { h, _ in
            let height = (h as? NSNumber).map { CGFloat(truncating: $0) } ?? wv.bounds.height
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: wv.bounds.width, height: max(height, wv.bounds.height))
            wv.createPDF(configuration: cfg) { result in
                guard case .success(let data) = result else { NSSound.beep(); return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = suggestedName
                if #available(macOS 12.0, *) { panel.allowedContentTypes = [.pdf] }
                panel.begin { resp in
                    guard resp == .OK, let url = panel.url else { return }
                    try? data.write(to: url)
                }
            }
        }
    }
}

/// The overlay panel: header (source hint, zoom, close) + the render webview.
/// Esc and ⌘+/−/0 are handled by a local key monitor while the panel is up.
struct RenderPanel: View {
    @EnvironmentObject var state: AppState
    let text: String

    @AppStorage("ut.renderFontSize") private var fontSize = 16.0
    @State private var copied = false
    @StateObject private var web = RenderWebProxy()

    // Light chrome to match the light document below it — the panel reads as a
    // "page" floating over the dark app, not more dark UI.
    private let paper = Color(hex: "#FBFBFA")
    private let inkDim = Color(hex: "#6E7681")

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Color(hex: "#B58A00"))
                    Text("Render").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: "#1F2328"))
                    Text("markdown · LaTeX · code").font(.system(size: 11)).foregroundStyle(inkDim)
                    Spacer()
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy Source", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11)).foregroundStyle(inkDim)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the extracted text the renderer received (handy for debugging a bad render)")
                    Button {
                        web.exportPDF(suggestedName: "\(state.selection?.session ?? "render").pdf")
                    } label: {
                        Label("PDF", systemImage: "arrow.down.doc")
                            .font(.system(size: 11)).foregroundStyle(inkDim)
                    }
                    .buttonStyle(.plain)
                    .help("Save the rendered document as a PDF")
                    HStack(spacing: 2) {
                        zoomButton("minus") { adjustZoom(-1) }
                        Text("\(Int(fontSize))").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(inkDim).frame(width: 22)
                        zoomButton("plus") { adjustZoom(1) }
                    }
                    Button { close() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                            .foregroundStyle(inkDim)
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                }
                .padding(.horizontal, 14).frame(height: 40)
                .background(paper)
                Rectangle().fill(Color(hex: "#E4E4E0")).frame(height: 1)
                RenderWebView(markdown: text, fontSize: fontSize, proxy: web)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.horizontal, 56)   // big: nearly the window, with a visible rim of app
            .padding(.vertical, 28)
        }
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
    }

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: "#57606A"))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.05)))
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
                case "0": fontSize = 16; return nil
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
    let proxy: RenderWebProxy

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        proxy.webView = wv
        wv.navigationDelegate = context.coordinator
        if #available(macOS 12.0, *) { wv.underPageBackgroundColor = NSColor(red: 0.984, green: 0.984, blue: 0.980, alpha: 1) }
        wv.setValue(false, forKey: "drawsBackground")   // panel paper shows through while loading
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
