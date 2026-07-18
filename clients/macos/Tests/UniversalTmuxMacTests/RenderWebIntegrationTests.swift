import WebKit
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class RenderWebIntegrationTests: XCTestCase {
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
                             presentation: String) async throws {
        let document: [String: Any] = [
            "id": UUID().uuidString,
            "source": source,
            "sourceOrigin": origin,
            "terminal": [
                "columns": 24,
                "fontFamily": "SF Mono",
                "background": "#11131A",
                "foreground": "#E8E9EE",
                "styles": [[
                    "foreground": "#0A78F0", "background": "#11131A",
                    "bold": true, "italic": false,
                    "underline": NSNull(), "underlineColor": NSNull(),
                    "strikethrough": false,
                ]],
                "lines": [
                    ["runs": [["text": "ANSI heading", "style": 0, "link": NSNull()]],
                     "wrapped": false],
                    ["runs": [["text": "└─ exact table", "style": 0, "link": NSNull()]],
                     "wrapped": false],
                ],
            ],
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
