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
            "window.UTRender.setLayout('artifact'); window.UTRender.set('# Wide reader\\n\\nReadable body.', 16)"
        )
        let value = try await webView.evaluateJavaScript(
            "({ body: document.body.getBoundingClientRect().width, viewport: document.documentElement.clientWidth, "
                + "artifact: document.documentElement.classList.contains('artifact-reader') })"
        )
        let metrics = try XCTUnwrap(value as? [String: Any])
        let bodyWidth = try XCTUnwrap(metrics["body"] as? NSNumber).doubleValue
        let viewportWidth = try XCTUnwrap(metrics["viewport"] as? NSNumber).doubleValue

        XCTAssertEqual(metrics["artifact"] as? Bool, true)
        XCTAssertGreaterThan(bodyWidth, 1_000, "Artifact reading must not fall back to the 740px Render folio")
        XCTAssertLessThanOrEqual(bodyWidth, viewportWidth - 48 + 1)
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

    func testTranscriptStylesRequireMatchingTerminalContext() async throws {
        let webView = try await loadRenderer()
        let source = """
        Measured uniformly using the emitted reasoning prefix—not hidden model internals:

        | Model/mode | Raw coverage | Mean CoT/action |
        |---|---:|---:|
        | Dense2305 full | 128/128 | **104.89** |
        | Router-trained Step900 router | 128/128 | **68.36** |
        | No-router Stage B step900 full | 128/128 | **89.86** |
        | Router-trained Step900 full | 128/128 | **70.31** |

        Main observations follow.
        """
        let terminal: [String: Any] = [
            "columns": 78,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [
                terminalStyle(foreground: "#E8E9EE"),
                terminalStyle(foreground: "#F1D18A", bold: true),
                terminalStyle(foreground: "#AAB2BD", background: "#31443A"),
                terminalStyle(foreground: "#AAB2BD", background: "#513040"),
                terminalStyle(foreground: "#35C46A", bold: true),
            ],
            "lines": [
                // Even an exact line repeated earlier must not override the
                // latest copy that belongs to the selected response.
                terminalLine([
                    terminalRun("Main "),
                    terminalRun("observations", style: 2),
                    terminalRun(" follow."),
                ]),
                terminalLine([]),
                // These styled fragments belong to an earlier diff in the same
                // scrollback snapshot. Bare substring replay used to paint the
                // matching fragments in the later response below.
                terminalLine([
                    terminalRun("Edited report: "),
                    terminalRun("reason", style: 2),
                    terminalRun(" "),
                    terminalRun("router", style: 2),
                    terminalRun(" "),
                    terminalRun("68", style: 2),
                    terminalRun(" "),
                    terminalRun("66", style: 3),
                    terminalRun(" "),
                    terminalRun("full", style: 2),
                ]),
                terminalLine([]),
                terminalLine([terminalRun("Measured uniformly using the emitted reasoning prefix—not hidden model internals:")]),
                terminalLine([]),
                terminalLine([
                    terminalRun(" Model/mode", style: 1),
                    terminalRun("                      "),
                    terminalRun("Raw coverage", style: 1),
                    terminalRun("    "),
                    terminalRun("Mean CoT/action", style: 1),
                ]),
                terminalLine([terminalRun(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")]),
                terminalLine([terminalRun(" Dense2305 full                   128/128         104.89")]),
                terminalLine([terminalRun(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")]),
                terminalLine([
                    terminalRun(" Router-                          128/128         "),
                    terminalRun("68.36", style: 4),
                ]),
                terminalLine([terminalRun(" trained")]),
                terminalLine([terminalRun(" Step900")]),
                terminalLine([terminalRun(" router")]),
                terminalLine([terminalRun(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")]),
                terminalLine([terminalRun(" No-router Stage B step900 full  128/128         89.86")]),
                terminalLine([terminalRun(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")]),
                terminalLine([terminalRun(" Router-trained Step900 full     128/128         70.31")]),
                terminalLine([terminalRun(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")]),
                terminalLine([]),
                terminalLine([terminalRun("Main observations follow.")]),
            ],
        ]
        try await setDocument(webView, source: source, origin: "codex-transcript",
                              presentation: "rendered", terminal: terminal)

        let report = try await inspect(webView)
        XCTAssertEqual(report.int("tables"), 1)
        XCTAssertTrue(report["error"] is NSNull || report["error"] == nil)

        let leakedBackgrounds = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.terminal-accent[style*=\"background-color\"]').length"
        ) as? NSNumber
        XCTAssertEqual(leakedBackgrounds?.intValue, 0)

        let styledHeader = try await webView.evaluateJavaScript(
            "document.querySelectorAll('th [data-terminal-style=\"1\"]').length"
        ) as? NSNumber
        XCTAssertEqual(styledHeader?.intValue, 3)

        let genuineValue = try await webView.evaluateJavaScript(
            "document.querySelector('td [data-terminal-style=\"4\"]')?.textContent"
        ) as? String
        XCTAssertEqual(genuineValue, "68.36")
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

    private func loadRenderer() async throws -> WKWebView {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700))
        let loaded = expectation(description: "offline renderer loaded")
        let delegate = NavigationWaiter(loaded)
        webView.navigationDelegate = delegate
        let testFile = URL(fileURLWithPath: #filePath)
        let macRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let renderDir = macRoot.appendingPathComponent("Resources/render", isDirectory: true)
        webView.loadFileURL(renderDir.appendingPathComponent("index.html"),
                            allowingReadAccessTo: renderDir)
        await fulfillment(of: [loaded], timeout: 8)
        withExtendedLifetime(delegate) {}
        return webView
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
