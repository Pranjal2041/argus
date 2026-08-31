import PDFKit
import WebKit
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class RenderWebIntegrationTests: XCTestCase {
    func testArtifactReaderUsesTheWideResponsiveLayout() async throws {
        let webView = try await loadRenderer()
        webView.frame = .init(x: 0, y: 0, width: 1_600, height: 900)
        _ = try await webView.evaluateJavaScript(
            "window.UTRender.setLayout('artifact'); "
                + "window.UTRender.setTheme({dark:true,bg:'#22232b',fg:'#d7d8df'}); "
                + "window.UTRender.set('# Source provenance for all environments\\n\\n"
                + "The prose keeps a readable line length while the structured evidence uses the available canvas.\\n\\n"
                + "| # | Benchmark environment | Exact stored anchor(s) |\\n"
                + "|---:|---|---|\\n"
                + "| 1 | Motion-Only Ghost Jigsaw | nextgen-captchas-benchmark/Spooky_Jigsaw |\\n"
                + "| 2 | Cursor-Controlled Constellation Hunt | captchastar-interactive-shape |', 16)"
        )
        let value = try await webView.evaluateJavaScript(
            "({ body: document.body.getBoundingClientRect().width, viewport: document.documentElement.clientWidth, "
                + "artifact: document.documentElement.classList.contains('artifact-reader'), "
                + "wide: document.documentElement.classList.contains('wide-content'), "
                + "table: document.querySelector('table').getBoundingClientRect().width, "
                + "prose: document.querySelector('p').getBoundingClientRect().width })"
        )
        let metrics = try XCTUnwrap(value as? [String: Any])
        let bodyWidth = try XCTUnwrap(metrics["body"] as? NSNumber).doubleValue
        let viewportWidth = try XCTUnwrap(metrics["viewport"] as? NSNumber).doubleValue
        let tableWidth = try XCTUnwrap(metrics["table"] as? NSNumber).doubleValue
        let proseWidth = try XCTUnwrap(metrics["prose"] as? NSNumber).doubleValue

        XCTAssertEqual(metrics["artifact"] as? Bool, true)
        XCTAssertEqual(metrics["wide"] as? Bool, true)
        XCTAssertGreaterThan(bodyWidth, viewportWidth - 2)
        XCTAssertGreaterThan(tableWidth, 1_300, "Structural content should receive the live viewport")
        XCTAssertLessThan(proseWidth, tableWidth, "Prose should keep a readable measure inside a wide document")

        if let path = ProcessInfo.processInfo.environment["UT_CAPTURE_ADAPTIVE_MARKDOWN"] {
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testPlainMarkdownKeepsAReadableMeasureUntilWideContentAppears() async throws {
        let webView = try await loadRenderer()
        webView.frame = .init(x: 0, y: 0, width: 1_600, height: 900)
        _ = try await webView.evaluateJavaScript(
            "window.UTRender.setLayout('compact'); window.UTRender.set('# Reading\\n\\nPlain prose only.', 16)"
        )
        let value = try await webView.evaluateJavaScript(
            "({ body: document.body.getBoundingClientRect().width, "
                + "wide: document.documentElement.classList.contains('wide-content') })"
        )
        let metrics = try XCTUnwrap(value as? [String: Any])
        let bodyWidth = try XCTUnwrap(metrics["body"] as? NSNumber).doubleValue

        XCTAssertEqual(metrics["wide"] as? Bool, false)
        XCTAssertLessThanOrEqual(bodyWidth, 821)
    }

    func testLabMainCanvasTracksTheLiveViewport() async throws {
        let webView = try await loadResource("lab")
        webView.frame = .init(x: 0, y: 0, width: 1_800, height: 900)
        _ = try await webView.evaluateJavaScript(#"""
            document.body.innerHTML = `
              <main class="main-content wide">
                <div class="eyebrow">Research index</div>
                <h1 class="display-title">All experiment runs</h1>
                <p class="lede">Readable context remains bounded while the experiment ledger uses the full workspace.</p>
                <div class="section-head"><h2>Runs</h2><span class="section-kicker">75 recorded experiments</span></div>
                <table class="ledger">
                  <thead><tr><th>Run</th><th>Phase</th><th>Tier / group</th><th>Latest result</th><th>Started</th></tr></thead>
                  <tbody><tr><td>R2521</td><td>Finished</td><td>full</td><td>Evaluation completed with verified evidence.</td><td>9h</td></tr></tbody>
                </table>
              </main>`;
        """#)
        let value = try await webView.evaluateJavaScript(
            "({ content: document.querySelector('.main-content').getBoundingClientRect().width, "
                + "ledger: document.querySelector('.ledger').getBoundingClientRect().width, "
                + "viewport: document.documentElement.clientWidth })"
        )
        let metrics = try XCTUnwrap(value as? [String: Any])
        let content = try XCTUnwrap(metrics["content"] as? NSNumber).doubleValue
        let ledger = try XCTUnwrap(metrics["ledger"] as? NSNumber).doubleValue
        let viewport = try XCTUnwrap(metrics["viewport"] as? NSNumber).doubleValue

        XCTAssertGreaterThan(content, viewport - 2)
        XCTAssertGreaterThan(ledger, 1_600)
        if let path = ProcessInfo.processInfo.environment["UT_CAPTURE_ADAPTIVE_LAB"] {
            try await capture(webView, to: path)
        }
    }

    func testMarkdownPagesModeCanCreateAnInMemoryPDF() async throws {
        let webView = try await loadRenderer()
        _ = try await webView.evaluateJavaScript(
            "window.UTRender.setLayout('artifact'); "
                + "window.UTRender.set('# In-app pages\\n\\nA **rendered** Markdown document.', 16)"
        )
        let proxy = MarkdownPreviewProxy()
        proxy.attach(webView)
        proxy.renderingFinished(successfully: true)

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            proxy.createPDF { continuation.resume(with: $0) }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertGreaterThan(data.count, 1_000)
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("In-app pages") == true)
        let pageWidth = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).width
        XCTAssertLessThan(pageWidth, webView.bounds.width - 20, "PDF pages should crop unused reader margins")
    }

    func testPDFCaptureProducesTheFullCurrentRenderedDocument() async throws {
        let webView = try await loadRenderer()
        let source = (1...80).map { "## Finding \($0)\n\nA saved result with **evidence** and enough body text to extend the document." }
            .joined(separator: "\n\n")
        try await setDocument(webView, source: source, origin: "codex-transcript",
                              presentation: "rendered")
        let proxy = RenderWebProxy()
        proxy.webView = webView

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            proxy.createPDF { continuation.resume(with: $0) }
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertGreaterThan(data.count, 1_000)
        XCTAssertEqual(pdf.pageCount, 1, "Render PDF is one full-document page, not a viewport screenshot")
        XCTAssertGreaterThan(try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).height,
                             webView.bounds.height)
    }

    func testRenderedPresentationHandlesMarkdownMathTablesCodeAndTerminalArtTogether() async throws {
        let webView = try await loadRenderer()
        let source = #"""
        # Analysis

        The inline result is \(x^2 + y^2\), and the display result is:

        \[
        R_{\rm TP}=D_{\rm KL}(p^*\Vert p)-D_{\rm KL}(p^*\Vert q_{c,\lambda}).
        \]

        | Condition | Exact |
        |---|---:|
        | Gold answer | **0.42** |

        See [the local report](/Users/example/project_with_underscores/report.pdf).

        ```swift
        let answer = 42
        ```

        ┌──────┬──────┐
        │ left │ right│
        └──────┴──────┘
        """#
        try await setDocument(webView, source: source, origin: "codex-transcript",
                              presentation: "rendered")

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("headings"), 1)
        XCTAssertEqual(report.int("tables"), 1)
        XCTAssertEqual(report.int("displayMath"), 1)
        XCTAssertEqual(report.int("inlineMath"), 1)
        XCTAssertEqual(report.int("links"), 1)
        XCTAssertEqual(report.int("codeBlocks"), 1)
        XCTAssertEqual(report.int("highlightedCode"), 1)
        XCTAssertEqual(report.int("verbatimBlocks"), 1)
        XCTAssertEqual(report.string("sourceOrigin"), "codex-transcript")
        XCTAssertTrue(report.string("text").contains("Gold answer"))
        XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)
    }

    func testProcessOwnedTranscriptRendersAsAuthoredDocumentInsteadOfTerminalFallback() async throws {
        let webView = try await loadRenderer()
        webView.frame = .init(x: 0, y: 0, width: 1_200, height: 760)
        let source = #"""
        # Completed report

        The exact process-owned transcript preserves the authored response.

        - Every progress fragment belongs to one logical turn.
        - Tool results do not split that turn.
        - The terminal grid remains an independent fallback.

        ```text
        provider-independent source selection
        ```
        """#
        try await setDocument(webView, source: source, origin: "claude-transcript",
                              presentation: "rendered")

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("headings"), 1)
        XCTAssertEqual(report.int("codeBlocks"), 1)
        XCTAssertEqual(report.int("terminalRows"), 0)
        XCTAssertEqual(report.string("sourceOrigin"), "claude-transcript")
        XCTAssertTrue(report.string("text").contains("Every progress fragment"))
        XCTAssertFalse(report.string("text").contains("ANSI heading"))
        XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)

        if let path = ProcessInfo.processInfo.environment["UT_CAPTURE_TRANSCRIPT_RENDER"] {
            try await capture(webView, to: path)
        }
    }

    func testRenderedFallbackRecoversOnlyTeXShapedStrippedDelimiters() async throws {
        let webView = try await loadRenderer()
        let source = #"""
        Ordinary [brackets] and (parentheses) stay prose.

        [
        \lambda(c)=\sqrt{\frac{2\varepsilon}{V_c}}.
        ]

        The budget is (\varepsilon) for this update.
        """#
        try await setDocument(webView, source: source, origin: "terminal",
                              presentation: "rendered")

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("displayMath"), 1)
        XCTAssertGreaterThanOrEqual(report.int("inlineMath"), 1)
        XCTAssertTrue(report.string("text").contains("Ordinary [brackets]"))
        XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)
    }

    func testRenderedTerminalFallbackKeepsBorderlessStyledTableTogether() async throws {
        let webView = try await loadRenderer()
        let source = """
        # Challenge audit

         Requirement                   Result
         ────────────────────────────  ─────────────────────────────────────────────
         Camera configuration          Pass. Camera settings are unrestricted.
                                       Organizer forum ruling applies.
         ────────────────────────────  ─────────────────────────────────────────────
         Controller/action space       Pass. No published restriction.
         ────────────────────────────  ─────────────────────────────────────────────

        The combined submission finished successfully.
        """
        let terminal: [String: Any] = [
            "columns": 92,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [
                terminalStyle(foreground: "#E8E9EE"),
                terminalStyle(foreground: "#35C46A", bold: true),
                terminalStyle(foreground: "#6E7681"),
            ],
            "lines": [
                terminalLine([terminalRun("# Challenge audit")]),
                terminalLine([]),
                terminalLine([terminalRun(" Requirement                   Result")]),
                terminalLine([terminalRun(" ────────────────────────────  ─────────────────────────────────────────────", style: 2)]),
                terminalLine([
                    terminalRun(" Camera configuration          "),
                    terminalRun("Pass", style: 1),
                    terminalRun(". Camera settings are unrestricted."),
                ]),
                terminalLine([terminalRun("                               Organizer forum ruling applies.")]),
                terminalLine([terminalRun(" ────────────────────────────  ─────────────────────────────────────────────", style: 2)]),
                terminalLine([
                    terminalRun(" Controller/action space       "),
                    terminalRun("Pass", style: 1),
                    terminalRun(". No published restriction."),
                ]),
                terminalLine([terminalRun(" ────────────────────────────  ─────────────────────────────────────────────", style: 2)]),
                terminalLine([]),
                terminalLine([
                    terminalRun("The combined submission finished "),
                    terminalRun("successfully", style: 1),
                    terminalRun("."),
                ]),
            ],
        ]
        try await setDocument(webView, source: source, origin: "terminal",
                              presentation: "rendered", terminal: terminal)

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("headings"), 1)
        XCTAssertEqual(report.int("terminalTables"), 1)
        XCTAssertEqual(report.int("terminalTableRows"), 3)
        XCTAssertEqual(report.int("verbatimBlocks"), 0)
        XCTAssertTrue(report.string("text").contains("Camera configuration"))
        XCTAssertTrue(report.string("text").contains("Organizer forum ruling applies."))
        XCTAssertTrue(report.string("text").contains("The combined submission finished successfully."))

        let passColor = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('table.terminal-table [data-terminal-style=\"1\"]')).color"
        ) as? String
        XCTAssertNotNil(passColor)
        XCTAssertNotEqual(passColor?.lowercased(), "rgb(31, 35, 40)")
        let proseAccent = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('p [data-terminal-style=\"1\"]')).color"
        ) as? String
        XCTAssertNotNil(proseAccent)
        XCTAssertNotEqual(proseAccent?.lowercased(), "rgb(31, 35, 40)")
        XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)
    }

    func testAuthoritativeTranscriptsNeverBorrowStylesFromTerminalScrollback() async throws {
        let webView = try await loadRenderer()
        let source = """
        The servo path is rejected, and the diffuser decision is between **Meross** for easiest automation, Airversa for refillable waterless oil, and ASAKUKI for lowest cost.
        """
        let terminal: [String: Any] = [
            "columns": 88,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [
                terminalStyle(foreground: "#E8E9EE"),
                terminalStyle(foreground: "#CDD6F4", background: "#213A2B"),
            ],
            "lines": [
                // A tool diff can contain independently wrapped fragments of
                // the exact authored response. Text alignment alone cannot
                // prove that these green insertion spans belong to the later
                // transcript occurrence.
                terminalLine([
                    terminalRun("The servo path is rejected, and the diffuser decision is between Meross for easiest", style: 1),
                ]),
                terminalLine([
                    terminalRun("automation, Airversa for refillable waterless oil, and ASAKUKI for lowest cost.", style: 1),
                ]),
                terminalLine([]),
                // The later terminal presentation has different wrapping and
                // no background. Both transcript providers must ignore the
                // entire ANSI frame rather than guessing between occurrences.
                terminalLine([
                    terminalRun("The servo path is rejected, and the diffuser decision is between Meross for "),
                ]),
                terminalLine([
                    terminalRun("easiest automation, Airversa for refillable waterless oil, and ASAKUKI for lowest cost."),
                ], wrapped: true),
            ],
        ]
        for origin in ["codex-transcript", "claude-transcript"] {
            try await setDocument(webView, source: source, origin: origin,
                                  presentation: "rendered", terminal: terminal)
            let report = try await inspect(webView)
            XCTAssertEqual(report.int("terminalAccents"), 0, origin)
            XCTAssertEqual(report.string("sourceOrigin"), origin)
            XCTAssertTrue(report.string("text").contains("ASAKUKI for lowest cost"))
            XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)
        }

        let semanticBold = try await webView.evaluateJavaScript(
            "document.querySelector('strong')?.textContent"
        ) as? String
        XCTAssertEqual(semanticBold, "Meross")
        if let path = ProcessInfo.processInfo.environment["UT_CAPTURE_TRANSCRIPT_STYLE_ISOLATION"] {
            try await capture(webView, to: path)
        }
    }

    func testTerminalFallbackDoesNotTurnURLWithUnderscoresIntoMath() async throws {
        let webView = try await loadRenderer()
        let source = """
        Old IROS document (https://github.com/example/vlnverse_emr/blob/main/challenge/README.md).
        """
        let terminal: [String: Any] = [
            "columns": 110,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [terminalStyle(foreground: "#E8E9EE")],
            "lines": [terminalLine([terminalRun(source)])],
        ]
        try await setDocument(webView, source: source, origin: "terminal",
                              presentation: "rendered", terminal: terminal)

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("inlineMath"), 0)
        XCTAssertEqual(report.int("displayMath"), 0)
        XCTAssertEqual(report.int("links"), 1)
        XCTAssertTrue(report.string("text").contains("vlnverse_emr"))
        XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)
    }

    func testTerminalTableRecoveryNeverConsumesFencedCode() async throws {
        let webView = try await loadRenderer()
        let source = #"""
        # Literal layout

        ```text
        ----------------  ----------------
        alpha             beta
        ```
        """#
        let terminal: [String: Any] = [
            "columns": 48,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [terminalStyle(foreground: "#E8E9EE")],
            "lines": [
                terminalLine([terminalRun("# Literal layout")]),
                terminalLine([]),
                terminalLine([terminalRun("```text")]),
                terminalLine([terminalRun("----------------  ----------------")]),
                terminalLine([terminalRun("alpha             beta")]),
                terminalLine([terminalRun("```")]),
            ],
        ]
        try await setDocument(webView, source: source, origin: "terminal",
                              presentation: "rendered", terminal: terminal)

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("headings"), 1)
        XCTAssertEqual(report.int("codeBlocks"), 1)
        XCTAssertEqual(report.int("terminalTables"), 0)
        XCTAssertTrue(report.string("text").contains("alpha             beta"))
        XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)
    }

    func testTerminalPresentationPreservesStyledRowsAsIndependentFallback() async throws {
        let webView = try await loadRenderer()
        try await setDocument(webView, source: "# This must not be parsed",
                              origin: "terminal", presentation: "terminal")

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("terminalRows"), 2)
        XCTAssertEqual(report.int("headings"), 0)
        XCTAssertTrue(report.string("text").contains("ANSI heading"))
        let color = try await webView.evaluateJavaScript(
            "document.querySelector('.terminal-row span').style.color") as? String
        XCTAssertEqual(color?.lowercased(), "rgb(10, 120, 240)")
    }

    func testTerminalPresentationKeepsRowsBeyondLegacyFourHundredLineTail() async throws {
        let webView = try await loadRenderer()
        let terminal: [String: Any] = [
            "columns": 24,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [terminalStyle(foreground: "#E8E9EE")],
            "lines": (0..<650).map { terminalLine([terminalRun("point-\($0)")]) },
        ]
        try await setDocument(webView, source: "point-0\npoint-649", origin: "terminal",
                              presentation: "terminal", terminal: terminal)

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("terminalRows"), 650)
        XCTAssertTrue(report.string("text").contains("point-0"))
        XCTAssertTrue(report.string("text").contains("point-649"))
    }

    func testChunkedTransportRendersADeepTerminalDocumentInsteadOfEmptyPlaceholder() async throws {
        let webView = try await loadRenderer()
        let terminal: [String: Any] = [
            "columns": 180,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [terminalStyle(foreground: "#E8E9EE")],
            "lines": (0..<12_000).map { index in
                terminalLine([terminalRun("deep-row-\(index) " + String(repeating: "evidence ", count: 8))])
            },
        ]
        let document: [String: Any] = [
            "id": UUID().uuidString,
            "source": "# Exact recovered answer\n\nThe final result is visible.",
            "sourceOrigin": "codex-transcript",
            "terminal": terminal,
        ]
        let data = try JSONSerialization.data(withJSONObject: document)

        _ = try await callRenderer(
            webView, "window.UTRender.beginDocumentPayload()", arguments: [:])
        for offset in stride(from: 0, to: data.count, by: 96 * 1024) {
            let chunk = data[offset..<min(data.count, offset + 96 * 1024)].base64EncodedString()
            _ = try await callRenderer(
                webView,
                "window.UTRender.appendDocumentPayload(chunk)",
                arguments: ["chunk": chunk])
        }
        _ = try await callRenderer(
            webView,
            "window.UTRender.commitDocumentPayload(px, presentation)",
            arguments: ["px": 16, "presentation": "rendered"])

        let report = try await inspect(webView)
        XCTAssertEqual(report.string("sourceOrigin"), "codex-transcript")
        XCTAssertTrue(report.string("text").contains("Exact recovered answer"))
        XCTAssertFalse(report.string("text").contains("Nothing to render"))
        XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)
    }

    private func loadRenderer() async throws -> WKWebView {
        try await loadResource("render")
    }

    private func loadResource(_ name: String) async throws -> WKWebView {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700))
        let loaded = expectation(description: "offline \(name) resource loaded")
        let delegate = NavigationWaiter(loaded)
        webView.navigationDelegate = delegate
        let testFile = URL(fileURLWithPath: #filePath)
        let macRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceDir = macRoot.appendingPathComponent("Resources/\(name)", isDirectory: true)
        webView.loadFileURL(resourceDir.appendingPathComponent("index.html"),
                            allowingReadAccessTo: resourceDir)
        await fulfillment(of: [loaded], timeout: 8)
        withExtendedLifetime(delegate) {}
        return webView
    }

    private func capture(_ webView: WKWebView, to path: String) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func setDocument(_ webView: WKWebView, source: String, origin: String,
                             presentation: String,
                             terminal customTerminal: [String: Any]? = nil) async throws {
        let terminal: [String: Any] = customTerminal ?? [
            "columns": 24,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [terminalStyle(foreground: "#0A78F0", bold: true)],
            "lines": [
                terminalLine([terminalRun("ANSI heading")]),
                terminalLine([terminalRun("└─ exact table")]),
            ],
        ]
        let document: [String: Any] = [
            "id": UUID().uuidString,
            "source": source,
            "sourceOrigin": origin,
            "terminal": terminal,
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript(
            "window.UTRender.setDocument(\(json), 16, \(jsString(presentation)))")
    }

    private func inspect(_ webView: WKWebView) async throws -> [String: Any] {
        let value = try await webView.evaluateJavaScript("window.UTRender.inspect()")
        return try XCTUnwrap(value as? [String: Any])
    }

    private func callRenderer(_ webView: WKWebView, _ script: String,
                              arguments: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                script, arguments: arguments, in: nil, in: .page
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    private func terminalStyle(foreground: String, background: String = "#11131A",
                               bold: Bool = false) -> [String: Any] {
        [
            "foreground": foreground, "background": background,
            "bold": bold, "italic": false,
            "underline": NSNull(), "underlineColor": NSNull(),
            "strikethrough": false,
        ]
    }

    private func terminalRun(_ text: String, style: Int = 0) -> [String: Any] {
        ["text": text, "style": style, "link": NSNull()]
    }

    private func terminalLine(_ runs: [[String: Any]], wrapped: Bool = false) -> [String: Any] {
        ["runs": runs, "wrapped": wrapped]
    }
}

private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) { self.expectation = expectation }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        XCTFail("renderer navigation failed: \(error)")
        expectation.fulfill()
    }
}

private extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? -1 }
    func string(_ key: String) -> String { self[key] as? String ?? "" }
}
