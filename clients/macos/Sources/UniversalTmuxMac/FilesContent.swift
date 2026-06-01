import AVKit
import AppKit
import PDFKit
import SwiftUI
import WebKit

private let paneBG = NSColor(red: 0.051, green: 0.055, blue: 0.071, alpha: 1)
private let editorBaseFont: CGFloat = 13   // CM6 base size; preview zoom multiplies it

// MARK: - CodeMirror 6 (text viewer/editor) in a WKWebView

/// Hosts the bundled CodeMirror 6 (Resources/codemirror). One web view persists
/// and is repainted via `UTEditor` calls as the selection/zoom/edit-mode changes,
/// so switching files, zooming, or toggling edit never reloads the editor.
struct CodeMirrorView: NSViewRepresentable {
    let text: String
    let filename: String
    let path: String        // document identity — content is pushed only when this changes
    let fontSize: CGFloat
    let editable: Bool
    let scrollToLine: Int?  // jump here once this file loads (terminal cmd+click)
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "ut")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        if #available(macOS 12.0, *) { wv.underPageBackgroundColor = paneBG }
        wv.wantsLayer = true
        wv.layer?.backgroundColor = paneBG.cgColor
        context.coordinator.webView = wv
        context.coordinator.pending = (text, filename, path, fontSize, editable)
        context.coordinator.scrollLine = scrollToLine
        let dir = Bundle.main.resourceURL!.appendingPathComponent("codemirror")
        wv.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.update(text, filename, path, fontSize, editable, scrollToLine)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onChange: (String) -> Void
        private var ready = false
        var pending: (String, String, String, CGFloat, Bool)?
        private var loadedPath: String?     // which file's content is in the editor
        private var curFont: CGFloat = 0
        private var curEditable = false
        var scrollLine: Int? = nil          // requested jump line for the loaded file
        private var curScrollLine: Int? = nil

        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let p = pending { load(p.0, p.1, p.2, p.3, p.4); pending = nil }
        }
        // Only (re)load the document when the FILE changes. On a same-file re-render
        // (e.g. a keystroke flipping `dirty`), the editor owns its content — we never
        // push text back in, so the cursor/scroll position is preserved. A bumped
        // saveTick pulls the LIVE content out via getContent() for a save.
        func update(_ text: String, _ name: String, _ path: String, _ font: CGFloat, _ editable: Bool, _ scrollLine: Int?) {
            self.scrollLine = scrollLine
            guard ready else { pending = (text, name, path, font, editable); return }
            if loadedPath != path {
                load(text, name, path, font, editable)
            } else {
                if curFont != font { setFont(font) }
                if curEditable != editable { setEditable(editable) }
                maybeScroll()   // re-clicking a different line in the same open file
            }
        }
        private func load(_ text: String, _ name: String, _ path: String, _ font: CGFloat, _ editable: Bool) {
            loadedPath = path
            curScrollLine = nil   // new document → allow a jump
            webView?.evaluateJavaScript("window.UTEditor.setContent(\(js(text)), \(js(name)), \(editable ? "false" : "true"))")
            curEditable = editable
            setFont(font)
            maybeScroll()
        }
        /// Jump to the requested line once (per file / per line change).
        private func maybeScroll() {
            guard let line = scrollLine, line != curScrollLine else { return }
            curScrollLine = line
            webView?.evaluateJavaScript("window.UTEditor.gotoLine(\(line))")
        }
        private func setFont(_ font: CGFloat) {
            curFont = font
            webView?.evaluateJavaScript("window.UTEditor.setFontSize(\(Int(font.rounded())))")
        }
        private func setEditable(_ editable: Bool) {
            curEditable = editable
            webView?.evaluateJavaScript("window.UTEditor.setEditable(\(editable ? "true" : "false"))")
        }
        func userContentController(_ u: WKUserContentController, didReceive message: WKScriptMessage) {
            if let d = message.body as? [String: Any], d["type"] as? String == "change",
               let text = d["text"] as? String {
                onChange(text)
            }
        }
        private func js(_ s: String) -> String {
            guard let d = try? JSONSerialization.data(withJSONObject: [s]),
                  let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
            return String(arr.dropFirst().dropLast())   // ["..."] -> "..."
        }
    }
}

// MARK: - PDF

struct PDFKitView: NSViewRepresentable {
    let data: Data
    let zoom: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.backgroundColor = paneBG
        v.autoScales = true
        v.document = PDFDocument(data: data)
        DispatchQueue.main.async {
            context.coordinator.fit = v.scaleFactorForSizeToFit
            v.autoScales = false
            v.scaleFactor = context.coordinator.fit * zoom
        }
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        let fit = context.coordinator.fit > 0 ? context.coordinator.fit : v.scaleFactorForSizeToFit
        v.scaleFactor = fit * zoom
    }
    final class Coordinator { var fit: CGFloat = 0 }
}

// MARK: - image (zoomable)

struct ImageViewer: View {
    let image: NSImage
    let zoom: CGFloat
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - audio/video (streamed from the broker via Range)

/// AppKit AVPlayerView (not SwiftUI's VideoPlayer, which crashes instantiating its
/// generic metadata in this SwiftPM build). The pane is keyed by URL, so a new file
/// makes a fresh view.
struct MediaPlayer: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = AVPlayer(url: url)
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

// MARK: - content dispatcher (with edit/save + zoom toolbar)

struct FileContentView: View {
    @ObservedObject var tab: FileTab

    private var isText: Bool { if case .text = tab.content { return true }; return false }
    private var zoomable: Bool {
        switch tab.content { case .text, .image, .pdf: return true; default: return false }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            pane
            toolbar.padding(10)
            saveShortcut
        }
        .background(zoomShortcuts)
    }

    @ViewBuilder private var pane: some View {
        switch tab.content {
        case .empty:
            hint("doc.text", "Select a file to preview")
        case .loading(let p):
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text((p as NSString).lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let t, let name, let path):
            CodeMirrorView(text: t, filename: name, path: path, fontSize: editorBaseFont * tab.zoom,
                           editable: tab.editing, scrollToLine: tab.pendingLine,
                           onChange: { tab.editorChanged($0) })   // persists; no .id
        case .image(let img):
            ImageViewer(image: img, zoom: tab.zoom).id(tab.selection ?? "")
        case .pdf(let data):
            PDFKitView(data: data, zoom: tab.zoom).id(tab.selection ?? "")
        case .media(let url):
            MediaPlayer(url: url).id(url)
        case .binary(let e):
            hint("doc.zipper", "\(e.name)\n\(byteSize(e.size)) · not a previewable text file")
        case .error(let m):
            hint("exclamationmark.triangle", m)
        }
    }

    @ViewBuilder private var toolbar: some View {
        if zoomable {
            HStack(spacing: 8) {
                if isText {
                    Button {
                        if tab.editing { tab.save(); tab.toggleEditing() } else { tab.toggleEditing() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.editing ? "checkmark.circle" : "pencil").font(.system(size: 10, weight: .semibold))
                            Text(tab.editing ? "Done" : "Edit").font(.system(size: 11, weight: .medium))
                        }.foregroundStyle(tab.editing ? Flat.accent : Flat.dim)
                    }.buttonStyle(.plain).help(tab.editing ? "Save & done" : "Edit")
                    if tab.editing {
                        Button { tab.save() } label: {
                            HStack(spacing: 4) {
                                if tab.dirty { Circle().fill(Flat.accent).frame(width: 5, height: 5) }
                                Text("Save").font(.system(size: 11, weight: .semibold))
                            }.foregroundStyle(tab.dirty ? Flat.accent : Flat.dim)
                        }.buttonStyle(.plain).help("Save (⌘S)")
                    }
                    Divider().frame(height: 14)
                }
                zBtn("minus") { tab.zoomOut() }
                Button { tab.zoomReset() } label: {
                    Text("\(Int((tab.zoom * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Flat.dim).frame(width: 38)
                }.buttonStyle(.plain).help("Reset zoom (⌘0)")
                zBtn("plus") { tab.zoomIn() }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Flat.hairline, lineWidth: 1))
        }
    }

    private func zBtn(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Flat.dim).frame(width: 22, height: 20)
        }.buttonStyle(.plain)
    }

    private var saveShortcut: some View {
        Button("") { tab.save() }.keyboardShortcut("s", modifiers: .command).opacity(0).frame(width: 0, height: 0)
    }

    private var zoomShortcuts: some View {
        ZStack {
            Button("") { tab.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            Button("") { tab.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("") { tab.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("") { tab.zoomReset() }.keyboardShortcut("0", modifiers: .command)
        }.opacity(0).frame(width: 0, height: 0)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func byteSize(_ n: Int64) -> String {
    if n < 1024 { return "\(n) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var v = Double(n) / 1024, i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
}
