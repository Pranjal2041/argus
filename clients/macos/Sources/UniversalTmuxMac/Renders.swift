import AppKit
import SwiftTerm
import SwiftUI
import WebKit

// MARK: - "Renders": authored document + exact terminal fallback (⇧⌘M)
//
// A terminal TUI often consumes the model's Markdown before painting it, so a
// capture cannot reconstruct every table delimiter or TeX escape. Render keeps
// two representations in one static document: strongly screen-matched authored
// source for the default rich view, and a styled SwiftTerm cell snapshot for an
// exact terminal fallback. The live pane is never touched.

struct RenderCellStyle: Codable, Equatable, Hashable {
    let foreground: String
    let background: String
    let bold: Bool
    let italic: Bool
    let underline: String?
    let underlineColor: String?
    let strikethrough: Bool
}

struct RenderTerminalRun: Codable, Equatable {
    let text: String
    let style: Int
    let link: String?
}

struct RenderTerminalLine: Codable, Equatable {
    let runs: [RenderTerminalRun]
    let wrapped: Bool
}

struct RenderTerminalSnapshot: Codable, Equatable {
    let columns: Int
    let fontFamily: String
    let background: String
    let foreground: String
    let styles: [RenderCellStyle]
    let lines: [RenderTerminalLine]
}

/// Everything the overlay needs, captured synchronously from one terminal frame.
/// The UUID makes repeated captures of identical text distinct SwiftUI values.
struct RenderDocument: Codable, Equatable, Identifiable {
    let id: UUID
    let source: String
    let sourceOrigin: String
    let terminal: RenderTerminalSnapshot

    init(source: String, styled: StyledTerminalText, view: TerminalView,
         sourceOrigin: String = "terminal", id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.sourceOrigin = sourceOrigin

        var styles: [RenderCellStyle] = []
        var styleIDs: [RenderCellStyle: Int] = [:]
        let lines = styled.lines.map { line in
            let runs = line.runs.map { run -> RenderTerminalRun in
                let resolved = view.resolvedAttributes(for: run.attribute)
                let foreground = (resolved[.foregroundColor] as? NSColor) ?? view.nativeForegroundColor
                let background = (resolved[.backgroundColor] as? NSColor) ?? view.nativeBackgroundColor
                let underline = Self.underlineName(run.attribute)
                let resolvedFont = resolved[.font] as? NSFont
                let style = RenderCellStyle(
                    foreground: Self.hex(foreground),
                    background: Self.hex(background),
                    bold: resolvedFont?.fontDescriptor.symbolicTraits.contains(.bold)
                        ?? run.attribute.style.contains(.bold),
                    italic: resolvedFont?.fontDescriptor.symbolicTraits.contains(.italic)
                        ?? run.attribute.style.contains(.italic),
                    underline: underline,
                    underlineColor: underline.flatMap { _ in
                        (resolved[.underlineColor] as? NSColor).map(Self.hex)
                    },
                    strikethrough: run.attribute.style.contains(.crossedOut)
                )
                let styleID: Int
                if let existing = styleIDs[style] {
                    styleID = existing
                } else {
                    styleID = styles.count
                    styleIDs[style] = styleID
                    styles.append(style)
                }
                return RenderTerminalRun(text: run.text, style: styleID, link: run.link)
            }
            return RenderTerminalLine(runs: runs, wrapped: line.isWrapped)
        }
        terminal = RenderTerminalSnapshot(
            columns: styled.columns,
            fontFamily: view.font.familyName ?? "SF Mono",
            background: Self.hex(view.nativeBackgroundColor),
            foreground: Self.hex(view.nativeForegroundColor),
            styles: styles,
            lines: lines
        )
    }

    private init(id: UUID, source: String, sourceOrigin: String,
                 terminal: RenderTerminalSnapshot) {
        self.id = id
        self.source = source
        self.sourceOrigin = sourceOrigin
        self.terminal = terminal
    }

    /// Replace only the semantic source. The terminal snapshot remains the
    /// exact frame captured on invocation, while a new id makes WebKit refresh.
    func withAuthoritativeSource(_ source: String, origin: String) -> RenderDocument {
        RenderDocument(id: UUID(), source: source, sourceOrigin: origin, terminal: terminal)
    }

    private static func underlineName(_ attribute: Attribute) -> String? {
        guard attribute.style.contains(.underline) || attribute.underlineStyle != .none else { return nil }
        switch attribute.underlineStyle {
        case .none, .single: return "solid"
        case .double: return "double"
        case .curly: return "wavy"
        case .dotted: return "dotted"
        case .dashed: return "dashed"
        }
    }

    private static func hex(_ color: NSColor) -> String {
        let value = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int((value.redComponent * 255).rounded()),
                      Int((value.greenComponent * 255).rounded()),
                      Int((value.blueComponent * 255).rounded()))
    }
}

private struct RenderSourceResponse: Decodable {
    let source: String
    let format: String
    let origin: String
    let confidence: Double
}

/// One entry point for every ⇧⌘M surface. Open immediately from the lossless
/// terminal frame, then upgrade to screen-matched transcript Markdown when the
/// broker can prove it belongs to this exact pane. Explicit selections always
/// win and are never replaced behind the user's back.
@MainActor
enum RenderLauncher {
    static func open(state: AppState, terminals: TerminalController) {
        guard let document = terminals.renderableDocument() else { return }
        state.renderArtifactContext = state.selection.flatMap { state.artifactContext(for: $0) }
        state.renderDocument = document
        guard document.sourceOrigin == "terminal",
              let ref = state.selection,
              let machine = state.machine(for: ref) else { return }

        let initialID = document.id
        Task {
            guard let response = await fetch(httpBase: machine.httpBase, session: ref.session),
                  response.format == "markdown",
                  !response.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !state.renderPDFCaptureInProgress,
                  state.renderDocument?.id == initialID else { return }
            state.renderDocument = document.withAuthoritativeSource(
                response.source, origin: response.origin)
        }
    }

    private static func fetch(httpBase: String, session: String) async -> RenderSourceResponse? {
        guard var components = URLComponents(string: httpBase + "/render-source") else { return nil }
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await brokerSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(RenderSourceResponse.self, from: data)
        } catch {
            return nil
        }
    }
}

enum RenderExtract {
    /// Per-line leading gutters that are unambiguously AGENT chrome (claude's
    /// `⏺` turn marker and `⎿` tool-result elbow). Box-drawing characters are
    /// deliberately NOT touched here anymore: they may be content the terminal
    /// already typeset (tables, rules) — the renderer's segmenter preserves
    /// those runs verbatim instead. Stripping them destroyed real tables.
    private static let gutterPrefixes = ["⏺ ", "⎿ "]

    /// Recover logical source from the exact same styled frame used by faithful
    /// mode. A wrapped visual row continues the prior row; a hard row boundary
    /// stays a newline. Keeping both views frame-identical avoids races where
    /// new terminal output arrives between two independent extractions.
    static func joiningWrappedRows(_ styled: StyledTerminalText) -> String {
        var logical: [String] = []
        for line in styled.lines {
            // TUIs commonly repaint the rest of a row with styled spaces. Those
            // cells are visually meaningful in Terminal mode, but in Markdown
            // two trailing spaces mean a forced line break. Strip them only
            // from the logical-source representation.
            let sourceText = String(line.text.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
            if line.isWrapped, !logical.isEmpty {
                logical[logical.count - 1] += sourceText
            } else {
                logical.append(sourceText)
            }
        }
        return logical.joined(separator: "\n")
    }

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

enum RenderCapture {
    /// Render is a snapshot of the complete terminal history still retained by
    /// SwiftTerm. Keeping this policy in one testable seam prevents a small
    /// status-oriented tail limit from silently returning to the document path.
    static func completeTerminal(_ terminal: Terminal) -> StyledTerminalText {
        terminal.getStyledText(maxVisualLines: nil)
    }
}

/// Bridge for panel-header actions that must reach the hosted WKWebView
/// (PDF export needs the live web view, not SwiftUI state).
@MainActor
final class RenderWebProxy: ObservableObject {
    weak var webView: WKWebView?

    /// Snapshot the FULL rendered document (not just the viewport) into a
    /// one-page PDF via WebKit's native renderer. The caller owns persistence:
    /// Render's PDF button archives these exact bytes before any optional export.
    func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let wv = webView else {
            completion(.failure(RenderPDFError.webViewUnavailable))
            return
        }
        wv.evaluateJavaScript("({ width: Math.max(document.body.scrollWidth, document.documentElement.scrollWidth), height: Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) })") { dimensions, _ in
            let values = dimensions as? [String: Any]
            let width = (values?["width"] as? NSNumber).map { CGFloat(truncating: $0) } ?? wv.bounds.width
            let height = (values?["height"] as? NSNumber).map { CGFloat(truncating: $0) } ?? wv.bounds.height
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: 0, y: 0,
                              width: max(width, wv.bounds.width),
                              height: max(height, wv.bounds.height))
            wv.createPDF(configuration: cfg) { result in
                completion(result)
            }
        }
    }
}

private enum RenderPDFError: LocalizedError {
    case webViewUnavailable

    var errorDescription: String? {
        "The rendered document is not ready yet."
    }
}

/// The overlay panel: header (source hint, zoom, close) + the render webview.
/// Esc and ⌘+/−/0 are handled by a local key monitor while the panel is up.
struct RenderPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var artifacts: ArtifactStore
    let document: RenderDocument

    @AppStorage("ut.renderFontSize") private var fontSize = 16.0
    @State private var presentation = "rendered"
    @State private var copied = false
    @State private var savingPDF = false
    @State private var savedArtifact: ArtifactRecord?
    @State private var pdfError: String?
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
                    Text(presentation == "terminal"
                         ? "exact terminal frame"
                         : document.sourceOrigin.hasSuffix("-transcript")
                            ? "Markdown · LaTeX · tables · code"
                            : "rendered from terminal source")
                        .font(.system(size: 11)).foregroundStyle(inkDim)
                    Spacer()
                    Picker("Presentation", selection: $presentation) {
                        Text("Rendered").tag("rendered")
                        Text("Terminal").tag("terminal")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .disabled(savingPDF)
                    .help("Rendered uses authoritative agent Markdown when available; Terminal preserves the exact styled grid")
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(document.source, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy Source", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11)).foregroundStyle(inkDim)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the extracted text the renderer received (handy for debugging a bad render)")
                    if let savedArtifact {
                        Label("Saved", systemImage: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: "#337A48"))
                        Button("View") {
                            artifacts.open(artifact: savedArtifact)
                            state.presentArtifacts()
                            close()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(hex: "#356A78"))
                        .help("Open this PDF in Artifacts")
                    } else {
                        Button { savePDF() } label: {
                            Group {
                                if savingPDF {
                                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                                } else {
                                    Label("PDF", systemImage: "arrow.down.doc")
                                        .font(.system(size: 11)).foregroundStyle(inkDim)
                                }
                            }
                            .frame(minWidth: 34)
                        }
                        .buttonStyle(.plain)
                        .disabled(savingPDF || state.renderArtifactContext == nil)
                        .help(state.renderArtifactContext == nil
                              ? "Select a panel before saving a PDF"
                              : "Save this exact document to Artifacts")
                    }
                    HStack(spacing: 2) {
                        zoomButton("minus") { adjustZoom(-1) }
                        Text("\(Int(fontSize))").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(inkDim).frame(width: 22)
                        zoomButton("plus") { adjustZoom(1) }
                    }
                    .disabled(savingPDF)
                    Button { close() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                            .foregroundStyle(inkDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(savingPDF)
                    .help("Close (Esc)")
                }
                .padding(.horizontal, 14).frame(height: 40)
                .background(paper)
                Rectangle().fill(Color(hex: "#E4E4E0")).frame(height: 1)
                RenderWebView(document: document, fontSize: fontSize,
                              presentation: presentation, proxy: web)
                    .background(presentation == "terminal"
                                ? Color(hex: document.terminal.background)
                                : paper)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.horizontal, 56)   // big: nearly the window, with a visible rim of app
            .padding(.vertical, 28)
        }
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
        .alert("Couldn’t save PDF", isPresented: Binding(
            get: { pdfError != nil },
            set: { if !$0 { pdfError = nil } }
        )) {
            Button("OK") { pdfError = nil }
        } message: {
            Text(pdfError ?? "The PDF could not be saved.")
        }
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
    private func close() {
        guard !savingPDF else { return }
        state.renderDocument = nil
        state.renderArtifactContext = nil
        state.renderPDFCaptureInProgress = false
    }

    private func savePDF() {
        guard !savingPDF, savedArtifact == nil,
              let panel = state.renderArtifactContext else { return }
        savingPDF = true
        state.renderPDFCaptureInProgress = true
        let capturedPresentation = presentation
        web.createPDF { result in
            switch result {
            case .failure(let error):
                savingPDF = false
                state.renderPDFCaptureInProgress = false
                pdfError = error.localizedDescription
            case .success(let data):
                Task {
                    do {
                        savedArtifact = try await artifacts.savePDF(
                            data,
                            panel: panel,
                            presentation: capturedPresentation
                        )
                    } catch {
                        pdfError = error.localizedDescription
                    }
                    savingPDF = false
                    state.renderPDFCaptureInProgress = false
                }
            }
        }
    }

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

/// WKWebView hosting the offline render bundle (Resources/render). The complete
/// static document is pushed on load; mode and zoom updates restyle in place.
private struct RenderWebView: NSViewRepresentable {
    let document: RenderDocument
    let fontSize: Double
    let presentation: String
    let proxy: RenderWebProxy

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        proxy.webView = wv
        wv.navigationDelegate = context.coordinator
        if #available(macOS 12.0, *) {
            wv.underPageBackgroundColor = presentation == "terminal"
                ? NSColor(hex: document.terminal.background)
                : NSColor(red: 0.984, green: 0.984, blue: 0.980, alpha: 1)
        }
        wv.setValue(false, forKey: "drawsBackground")   // panel paper shows through while loading
        context.coordinator.pending = (document, fontSize, presentation)
        let dir = Bundle.main.resourceURL!.appendingPathComponent("render")
        wv.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        if #available(macOS 12.0, *) {
            wv.underPageBackgroundColor = presentation == "terminal"
                ? NSColor(hex: document.terminal.background)
                : NSColor(red: 0.984, green: 0.984, blue: 0.980, alpha: 1)
        }
        context.coordinator.update(wv, document, fontSize, presentation)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var pending: (RenderDocument, Double, String)?
        private var ready = false
        private var shownDocument: UUID?
        private var shownSize: Double = 0
        private var shownPresentation = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let p = pending { push(webView, p.0, p.1, p.2); pending = nil }
        }
        func update(_ wv: WKWebView, _ document: RenderDocument, _ size: Double, _ presentation: String) {
            guard ready else { pending = (document, size, presentation); return }
            if shownDocument != document.id || shownPresentation != presentation {
                push(wv, document, size, presentation)
            }
            else if shownSize != size {
                shownSize = size
                wv.evaluateJavaScript("window.UTRender.setZoom(\(Int(size)))")
            }
        }
        private func push(_ wv: WKWebView, _ document: RenderDocument, _ size: Double, _ presentation: String) {
            shownDocument = document.id
            shownSize = size
            shownPresentation = presentation
            wv.evaluateJavaScript(
                "window.UTRender.setDocument(\(js(document)), \(Int(size)), \(js(presentation)))"
            )
        }
        private func js<T: Encodable>(_ value: T) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8) else { return "null" }
            return encoded
        }
    }
}
