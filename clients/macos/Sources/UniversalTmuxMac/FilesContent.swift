import AVKit
import AppKit
import PDFKit
import SwiftUI
import WebKit

private var paneBG: NSColor { Theme.nsAppBackground }   // themed (was hardcoded #0d0e12)
private let editorBaseFont: CGFloat = 13   // CM6 base size; preview zoom multiplies it

// MARK: - CodeMirror 6 (text viewer/editor) in a WKWebView

/// Hosts the bundled Monaco editor (VS Code's editor, Resources/monaco). One web
/// view persists and is repainted via `UTEditor` calls as the selection/zoom/theme
/// changes, so switching files or zooming never reloads the editor.
struct CodeMirrorView: NSViewRepresentable {
    let text: String
    let filename: String
    let path: String        // document identity — content is pushed only when this changes
    let fontSize: CGFloat
    let editable: Bool
    let scrollToLine: Int?  // jump here once this file loads (terminal cmd+click)
    let onChange: (String) -> Void
    var onSave: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onSave: onSave) }

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
        let dir = Bundle.main.resourceURL!.appendingPathComponent("monaco")
        wv.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onSave = onSave
        context.coordinator.update(text, filename, path, fontSize, editable, scrollToLine)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onChange: (String) -> Void
        var onSave: () -> Void
        private var ready = false
        var pending: (String, String, String, CGFloat, Bool)?
        private var loadedPath: String?     // which file's content is in the editor
        private var curFont: CGFloat = 0
        private var curEditable = false
        var scrollLine: Int? = nil          // requested jump line for the loaded file
        private var curScrollLine: Int? = nil

        init(onChange: @escaping (String) -> Void, onSave: @escaping () -> Void) {
            self.onChange = onChange; self.onSave = onSave
        }

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
            applyTheme()          // match the app theme before painting the document
            webView?.evaluateJavaScript("window.UTEditor.setContent(\(js(text)), \(js(name)), \(editable ? "false" : "true"))")
            curEditable = editable
            setFont(font)
            maybeScroll()
        }
        /// Build a Monaco theme from the active app palette so the editor matches the app
        /// (token colors come from VS Code's own light/dark theme; chrome colors are ours).
        func applyTheme() {
            func hex(_ c: NSColor, _ alpha: String = "") -> String {
                let s = c.usingColorSpace(.sRGB) ?? c
                return String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255)) + alpha
            }
            let base = Theme.current.isLight ? "vs" : "vs-dark"
            let lineHl = Theme.current.isLight ? "#0000000a" : "#ffffff0d"
            let spec = "{base:'\(base)',bg:'\(hex(Theme.nsAppBackground))',fg:'\(hex(Theme.nsForeground))',accent:'\(hex(Theme.nsCursor))',selection:'\(hex(Theme.nsCursor, "33"))',lineHighlight:'\(lineHl)'}"
            webView?.evaluateJavaScript("window.UTEditor.setTheme(\(spec))")
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
            guard let d = message.body as? [String: Any], let type = d["type"] as? String else { return }
            switch type {
            case "change": if let text = d["text"] as? String { onChange(text) }
            case "save":   onSave()   // ⌘S pressed while focus is inside the editor
            default:       break
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

// MARK: - content area: an open-file tab strip + the active document's pane

struct FileContentView: View {
    @ObservedObject var tab: FileTab

    var body: some View {
        VStack(spacing: 0) {
            if !tab.openDocs.isEmpty {
                DocTabStrip(tab: tab)
                Divider().overlay(Flat.hairline)
            }
            if let doc = tab.activeDoc {
                DocPane(tab: tab, doc: doc).id(doc.id)
            } else {
                fileHint("doc.text", "Select a file to open")
            }
        }
    }
}

private func fileHint(_ symbol: String, _ text: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
}

// MARK: open-file tabs (VS Code-style, one chip per open document)

private struct DocTabStrip: View {
    @ObservedObject var tab: FileTab
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) { ForEach(tab.openDocs) { DocChip(tab: tab, doc: $0) } }
        }
        .frame(height: 34)
        .background(Flat.sidebar)
    }
}

private struct DocChip: View {
    @ObservedObject var tab: FileTab
    @ObservedObject var doc: OpenDoc
    var body: some View {
        let active = doc.id == tab.activeDocID
        HStack(spacing: 6) {
            Image(systemName: iconForFile(doc.name)).font(.system(size: 10)).foregroundStyle(active ? Flat.accent : Flat.faint)
            Text(doc.name).font(.system(size: 12, weight: active ? .medium : .regular))
                .foregroundStyle(active ? Flat.text : Flat.dim).lineLimit(1)
            Button { tab.closeDoc(doc.id) } label: {
                Image(systemName: doc.dirty ? "circle.fill" : "xmark")
                    .font(.system(size: doc.dirty ? 7 : 8, weight: .bold))
                    .frame(width: 12, height: 12)
            }.buttonStyle(.plain).foregroundStyle(doc.dirty ? Flat.accent : Flat.faint)
                .help(doc.dirty ? "Unsaved — close (discards changes)" : "Close")
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(active ? Flat.bg : Color.clear)
        .overlay(alignment: .top) { if active { Rectangle().fill(Flat.accent).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Flat.hairline).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { tab.activate(doc) }
    }
}

// MARK: the active document's pane (editor / image / pdf / media, + markdown preview)

private struct DocPane: View {
    @ObservedObject var tab: FileTab
    @ObservedObject var doc: OpenDoc

    private var isText: Bool { if case .text = doc.content { return true }; return false }
    private var zoomable: Bool {
        switch doc.content { case .text, .image, .pdf: return true; default: return false }
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
        switch doc.content {
        case .empty:
            fileHint("doc.text", "Empty")
        case .loading(let p):
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text((p as NSString).lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let t, let name, let path):
            textPane(t, name, path)
        case .image(let img):
            ImageViewer(image: img, zoom: doc.zoom)
        case .pdf(let data):
            PDFKitView(data: data, zoom: doc.zoom)
        case .media(let url):
            MediaPlayer(url: url).id(url)
        case .binary(let e):
            fileHint("doc.zipper", "\(e.name)\n\(byteSize(e.size)) · not a previewable text file")
        case .error(let m):
            fileHint("exclamationmark.triangle", m)
        }
    }

    @ViewBuilder private func textPane(_ t: String, _ name: String, _ path: String) -> some View {
        let editor = CodeMirrorView(text: t, filename: name, path: path, fontSize: editorBaseFont * doc.zoom,
                                    editable: true, scrollToLine: doc.pendingLine,
                                    onChange: { doc.editorChanged($0) }, onSave: { tab.save() })
        let mdSource = doc.dirty ? doc.draft : t   // live as you type
        if doc.isMarkdown && doc.previewMode == .preview {
            MarkdownPreviewView(markdown: mdSource, fontSize: Double(editorBaseFont * doc.zoom))
        } else if doc.isMarkdown && doc.previewMode == .split {
            HSplitView {
                editor.frame(minWidth: 240)
                MarkdownPreviewView(markdown: mdSource, fontSize: Double(editorBaseFont * doc.zoom)).frame(minWidth: 240)
            }
        } else {
            editor
        }
    }

    @ViewBuilder private var toolbar: some View {
        if zoomable {
            HStack(spacing: 8) {
                if doc.isMarkdown {
                    ForEach([PreviewMode.editor, .split, .preview], id: \.self) { m in
                        Button { doc.previewMode = m } label: {
                            Image(systemName: mdIcon(m)).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(doc.previewMode == m ? Flat.accent : Flat.dim)
                                .frame(width: 20, height: 18)
                        }.buttonStyle(.plain).help(m.rawValue.capitalized)
                    }
                    Divider().frame(height: 14)
                }
                if isText {
                    Button { tab.save() } label: {
                        HStack(spacing: 4) {
                            if doc.dirty { Circle().fill(Flat.accent).frame(width: 5, height: 5) }
                            Image(systemName: doc.dirty ? "arrow.down.circle" : "checkmark.circle").font(.system(size: 10, weight: .semibold))
                            Text(doc.dirty ? "Save" : "Saved").font(.system(size: 11, weight: .medium))
                        }.foregroundStyle(doc.dirty ? Flat.accent : Flat.dim)
                    }.buttonStyle(.plain).help("Save (⌘S)").disabled(!doc.dirty)
                    Divider().frame(height: 14)
                }
                zBtn("minus") { doc.zoomOut() }
                Button { doc.zoomReset() } label: {
                    Text("\(Int((doc.zoom * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Flat.dim).frame(width: 38)
                }.buttonStyle(.plain).help("Reset zoom (⌘0)")
                zBtn("plus") { doc.zoomIn() }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Flat.hairline, lineWidth: 1))
        }
    }

    private func mdIcon(_ m: PreviewMode) -> String {
        switch m {
        case .editor:  return "chevron.left.forwardslash.chevron.right"
        case .split:   return "rectangle.split.2x1"
        case .preview: return "eye"
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
            Button("") { doc.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            Button("") { doc.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("") { doc.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("") { doc.zoomReset() }.keyboardShortcut("0", modifiers: .command)
        }.opacity(0).frame(width: 0, height: 0)
    }
}

// MARK: - markdown preview (reuses the offline render bundle: marked + KaTeX + hljs)

private struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.navigationDelegate = context.coordinator
        if #available(macOS 12.0, *) { wv.underPageBackgroundColor = NSColor(red: 0.984, green: 0.984, blue: 0.980, alpha: 1) }
        context.coordinator.pending = (markdown, fontSize)
        let dir = Bundle.main.resourceURL!.appendingPathComponent("render")
        wv.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        return wv
    }
    func updateNSView(_ wv: WKWebView, context: Context) { context.coordinator.update(wv, markdown, fontSize) }

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
            else if shownSize != size { shownSize = size; wv.evaluateJavaScript("window.UTRender.setZoom(\(Int(size)))") }
        }
        private func push(_ wv: WKWebView, _ text: String, _ size: Double) {
            shownText = text; shownSize = size
            wv.evaluateJavaScript("window.UTRender.set(\(js(text)), \(Int(size)))")
        }
        private func js(_ s: String) -> String {
            guard let d = try? JSONSerialization.data(withJSONObject: [s]),
                  let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
            return String(arr.dropFirst().dropLast())
        }
    }
}

func byteSize(_ n: Int64) -> String {
    if n < 1024 { return "\(n) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var v = Double(n) / 1024, i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
}
