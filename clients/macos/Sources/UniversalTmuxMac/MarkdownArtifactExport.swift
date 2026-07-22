import Combine
import Foundation
import WebKit

enum MarkdownArtifactExportError: LocalizedError {
    case rendererNotReady
    case pandocUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .rendererNotReady:
            return "The Markdown preview is still loading. Try the PDF export again in a moment."
        case .pandocUnavailable:
            return "EPUB export needs Pandoc. Install it with ‘brew install pandoc’, then try again."
        case .conversionFailed(let detail):
            return detail.isEmpty ? "Pandoc could not create the EPUB." : "Pandoc could not create the EPUB: \(detail)"
        }
    }
}

/// A narrow bridge from the Markdown reader to WebKit's native PDF capture.
/// The preview remains the source of truth, so the PDF matches the document the
/// user is actually reading (including Markdown tables, syntax color, and math).
@MainActor
final class MarkdownPreviewProxy: ObservableObject {
    weak var webView: WKWebView?
    @Published private(set) var isReady = false

    func attach(_ webView: WKWebView) {
        if self.webView !== webView {
            self.webView = webView
            isReady = false
        }
    }

    func renderingStarted() {
        isReady = false
    }

    func renderingFinished(successfully: Bool) {
        isReady = successfully
    }

    func createPDF(completion: @escaping (Result<Data, Error>) -> Void) {
        guard isReady, let webView else {
            completion(.failure(MarkdownArtifactExportError.rendererNotReady))
            return
        }
        webView.evaluateJavaScript(
            "(() => { const body = document.body.getBoundingClientRect(); return { x: body.left, "
                + "width: body.width, height: Math.max(document.body.scrollHeight, "
                + "document.documentElement.scrollHeight) }; })()"
        ) { dimensions, error in
            if let error {
                completion(.failure(error))
                return
            }
            let values = dimensions as? [String: Any]
            let x = (values?["x"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
            let width = (values?["width"] as? NSNumber).map { CGFloat(truncating: $0) }
                ?? webView.bounds.width
            let height = (values?["height"] as? NSNumber).map { CGFloat(truncating: $0) }
                ?? webView.bounds.height
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(
                x: max(0, x),
                y: 0,
                width: max(1, width),
                height: max(height, webView.bounds.height)
            )
            webView.createPDF(configuration: configuration, completionHandler: completion)
        }
    }
}

/// EPUB is deliberately an export, not a second artifact record. That keeps
/// one canonical Markdown snapshot in the library while still offering a
/// portable, reflowable reading copy on demand.
enum MarkdownEPUBExporter {
    static func suggestedTitle(for filename: String) -> String {
        let title = (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasReadableCharacter = title.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
        return hasReadableCharacter ? title : "Argus Markdown"
    }

    static func pandocURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates = [
            "/opt/homebrew/bin/pandoc",
            "/usr/local/bin/pandoc",
            "/usr/bin/pandoc",
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/pandoc" })
        }
        var seen = Set<String>()
        return candidates.first { seen.insert($0).inserted && fileManager.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    static func export(sourceURL: URL, destinationURL: URL, title: String) async throws {
        guard let pandoc = pandocURL() else {
            throw MarkdownArtifactExportError.pandocUnavailable
        }
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let temporaryURL = fileManager.temporaryDirectory
                .appendingPathComponent("argus-markdown-\(UUID().uuidString).epub")
            defer { try? fileManager.removeItem(at: temporaryURL) }

            let process = Process()
            let diagnostics = Pipe()
            process.executableURL = pandoc
            process.currentDirectoryURL = sourceURL.deletingLastPathComponent()
            process.arguments = [
                sourceURL.path,
                "--from=gfm",
                "--to=epub3",
                "--standalone",
                "--metadata=title:\(title)",
                "--resource-path=\(sourceURL.deletingLastPathComponent().path)",
                "--output=\(temporaryURL.path)",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = diagnostics

            try process.run()
            let diagnosticData = diagnostics.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(data: diagnosticData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw MarkdownArtifactExportError.conversionFailed(detail)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        }.value
    }
}
