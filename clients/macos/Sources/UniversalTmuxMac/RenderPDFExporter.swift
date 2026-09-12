import PDFKit
import WebKit

/// Export is a document operation, not a screenshot of scrolling containers.
/// Freeze the current owned renderer into a separate view, expand its clipped
/// surfaces, and capture the resulting geometry. Never mutate the live preview.
@MainActor
enum RenderPDFExporter {
    enum Failure: LocalizedError {
        case notReady, invalidGeometry, tooWide, invalidPDF, timedOut
        var errorDescription: String? {
            switch self {
            case .notReady: return "The rendered document is not ready for PDF export."
            case .invalidGeometry: return "The complete document could not be measured. No cropped PDF was saved."
            case .tooWide: return "This document exceeds the PDF page-width limit. Reduce the render font size and try again; no cropped PDF was saved."
            case .invalidPDF: return "WebKit did not produce a complete PDF. No partial PDF was saved."
            case .timedOut: return "The document's resources did not finish loading. No partial PDF was saved."
            }
        }
    }

    static func create(from source: WKWebView, completion: @escaping (Result<Data, Error>) -> Void) {
        Task { @MainActor in
            do { completion(.success(try await capture(source))) }
            catch { completion(.failure(error)) }
        }
    }

    private static func capture(_ source: WKWebView) async throws -> Data {
        // Only used by Argus's bundled renderer, never a third-party website.
        let value = try await source.evaluateJavaScript(#"""
            (() => {
              if (!window.UTRender || window.UTRender.lastError || !document.getElementById('out')) return null;
              const copy = document.documentElement.cloneNode(true);
              copy.querySelectorAll('script').forEach(node => node.remove());
              return '<!doctype html>' + copy.outerHTML;
            })()
            """#)
        guard let html = value as? String, let sourceURL = source.url, sourceURL.isFileURL else { throw Failure.notReady }
        // File-origin styles cannot be read through CSSOM, and loadHTMLString
        // does not inherit the preview's resource access grant. Give this
        // frozen document its own private copy of the owned offline resources.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argus-pdf-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: sourceURL.deletingLastPathComponent(), to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("pdf-snapshot.html")
        try html.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(origin: .zero, size: source.bounds.size), configuration: config)
        let loader = Loader()
        view.navigationDelegate = loader
        try await loader.load(view, url: snapshotURL)
        // Await font/image decoding before measuring; no timer-based layout guess.
        _ = try await view.callAsyncJavaScript(#"""
            await Promise.race([
              Promise.all([document.fonts.ready, ...Array.from(document.images).map(image => image.decode())]),
              new Promise((_, reject) => setTimeout(() => reject(new Error('PDF resources timed out')), 20000))
            ]);
            const style = document.createElement('style');
            style.textContent = `
              html, body { overflow: visible !important; }
              .table-scroll, pre, .katex-display, .terminal-page {
                overflow: visible !important; max-height: none !important;
                height: auto !important; contain: none !important;
              }
              .jtoggle { display: none !important; }
              pre:not(.term) { white-space: pre-wrap !important; overflow-wrap: anywhere !important; }
            `;
            document.head.appendChild(style);
            // Also expand nested/custom scroll boxes, independent of markup type.
            // Children first: expanding an inner box can expose overflow that
            // was previously invisible to its fixed-size outer container.
            for (const element of Array.from(document.querySelectorAll('#out *')).reverse()) {
              const s = getComputedStyle(element);
              if (s.display === 'none' || s.visibility === 'hidden') continue;
              if (s.clip !== 'auto' || s.clipPath !== 'none') continue;
              // Empty clipped graphics are decoration (e.g. a formula's radical
              // glyph), not scrollable document text. Preserve their clipping.
              if (!element.textContent.trim()) continue;
              if ((element.scrollWidth > element.clientWidth + 1 || element.scrollHeight > element.clientHeight + 1)
                  && /auto|scroll|hidden|clip/.test(s.overflowX + ' ' + s.overflowY)) {
                element.style.setProperty('overflow', 'visible', 'important');
                element.style.setProperty('max-height', 'none', 'important');
                element.style.setProperty('height', 'auto', 'important');
                element.style.setProperty('contain', 'none', 'important');
              }
            }
            return true;
            """#, arguments: [:], in: nil, contentWorld: .page)
        let measured = try await view.evaluateJavaScript(#"""
            (() => {
              const body = document.body.getBoundingClientRect();
              let left = body.left, right = body.right, bottom = body.bottom;
              const styles = new Map();
              const style = e => { if (!styles.has(e)) styles.set(e, getComputedStyle(e)); return styles.get(e); };
              for (const element of document.querySelectorAll('#out, #out *')) {
                const s = style(element);
                if (s.display === 'none' || s.visibility === 'hidden') continue;
                const r = element.getBoundingClientRect();
                if (!r.width || !r.height) continue;
                let l = r.left, t = r.top, b = r.bottom, end = r.right, hidden = false;
                for (let parent = element; parent; parent = parent.parentElement) {
                  const p = style(parent);
                  if (p.display === 'none' || p.visibility === 'hidden' || p.clip !== 'auto' || p.clipPath !== 'none') { hidden = true; break; }
                  if (parent === element) continue;
                  const box = parent.getBoundingClientRect();
                  if (/hidden|clip|auto|scroll/.test(p.overflowX)) { l = Math.max(l, box.left); end = Math.min(end, box.right); }
                  if (/hidden|clip|auto|scroll/.test(p.overflowY)) { t = Math.max(t, box.top); b = Math.min(b, box.bottom); }
                }
                if (hidden || end <= l || b <= t) continue;
                left = Math.min(left, l); right = Math.max(right, end);
                bottom = Math.max(bottom, b);
              }
              // Never cut a text line, table row, formula or image between pages.
              const intervals = [];
              const add = r => { if (r.width && r.height) intervals.push([r.top, r.bottom]); };
              const walker = document.createTreeWalker(document.getElementById('out'), NodeFilter.SHOW_TEXT);
              while (walker.nextNode()) {
                const range = document.createRange(); range.selectNodeContents(walker.currentNode);
                Array.from(range.getClientRects()).forEach(add);
              }
              document.querySelectorAll('tr, img, svg, .katex-display').forEach(e => add(e.getBoundingClientRect()));
              return { x: Math.floor(left), width: Math.ceil(right - left + 24), height: Math.ceil(bottom), intervals };
            })()
            """#)
        guard let size = measured as? [String: Any], let x = (size["x"] as? NSNumber)?.doubleValue,
              let width = (size["width"] as? NSNumber)?.doubleValue, let height = (size["height"] as? NSNumber)?.doubleValue,
              x.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else { throw Failure.invalidGeometry }
        // PDF 1.x readers commonly limit page dimensions to 14,400 points.
        // Split long documents instead of silently generating an invalid page.
        guard width <= 14_000 else { throw Failure.tooWide }
        let result = PDFDocument()
        let intervals = size["intervals"] as? [[Double]] ?? []
        var top = 0.0
        while top < height {
            var end = min(top + 12_000, height)
            if end < height {
                while let start = intervals.filter({ $0.count == 2 && $0[0] < end && $0[1] > end }).map({ $0[0] }).min() {
                    end = floor(start)
                }
            }
            guard end > top else { throw Failure.invalidGeometry }
            let pageHeight = end - top
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: x, y: top, width: width, height: pageHeight)
            let data = try await view.pdf(configuration: cfg)
            guard let part = PDFDocument(data: data), part.pageCount == 1, let page = part.page(at: 0) else { throw Failure.invalidPDF }
            result.insert(page, at: result.pageCount)
            top += pageHeight
        }
        guard let data = result.dataRepresentation(), !data.isEmpty else { throw Failure.invalidPDF }
        return data
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeout: Task<Void, Never>?
        func load(_ view: WKWebView, url: URL) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { @MainActor [weak self, weak view] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    self?.finish(Failure.timedOut)
                    view?.stopLoading()
                }
                view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(Failure.invalidPDF) }
        private func finish(_ error: Error?) {
            guard let c = continuation else { return }; continuation = nil
            timeout?.cancel(); timeout = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}
