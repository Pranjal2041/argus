import Foundation
import WebKit

/// The Dashboard browser uses the system WebKit engine, but a bare macOS
/// `WKWebView` identifies itself only as AppleWebKit. Strict browser allowlists
/// consequently classify it as an unknown embedded browser even though it is the
/// same stable engine used by the installed Safari release.
///
/// Append Safari's host-installed product identity instead of freezing Argus to a
/// guessed version. The native AppleWebKit prefix remains untouched.
enum ArgusBrowserIdentity {
    /// Embedded pages must not be able to turn a normal/hidden Argus browser tab
    /// into an OS-level display-capture request. WebKit has no public delegate for
    /// approving display capture (its media delegate covers camera/microphone), so
    /// deny getDisplayMedia in the page world before site code runs. This leaves
    /// ordinary browser screenshots, camera, microphone, and page interaction alone.
    static let disableDisplayCaptureScript = #"""
    (() => {
      const mediaDevices = navigator.mediaDevices;
      if (!mediaDevices) return;
      const deny = () => Promise.reject(new DOMException(
        'Display capture is disabled inside Argus', 'NotAllowedError'
      ));
      const targets = [mediaDevices, Object.getPrototypeOf(mediaDevices)];
      for (const target of targets) {
        if (!target) continue;
        try {
          Object.defineProperty(target, 'getDisplayMedia', {
            value: deny, writable: false, configurable: false
          });
        } catch (_) {}
      }
    })();
    """#

    static let safariVersion: String = {
        let candidates = [
            "/Applications/Safari.app",
            "/System/Applications/Safari.app",
        ]
        for path in candidates {
            guard let value = Bundle(path: path)?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                continue
            }
            let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty { return version }
        }

        // Safari's major release follows macOS on current systems. This fallback
        // is only for stripped test environments where the Safari bundle is absent.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion)"
    }()

    static var applicationNameForUserAgent: String {
        "Version/\(safariVersion) Safari/605.1.15"
    }

    static func persistentConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = applicationNameForUserAgent
        configuration.userContentController.addUserScript(WKUserScript(
            source: disableDisplayCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        return configuration
    }
}

/// A native permission boundary shared by every Argus web view that can load a
/// remote page. The public WebKit delegate covers camera and microphone. WebKit
/// exposes its display-capture decision only through its Cocoa delegate selector,
/// so implement that selector as well and always return the documented deny value
/// (`WKDisplayCapturePermissionDecisionDeny == 0`). This runs in WebKit's UI
/// process before a page can escalate its status check into the native picker or
/// a user-facing Screen Recording request. (WebKit may still perform a non-prompting
/// permission preflight.) The document-start script above remains defense in depth
/// for page JavaScript.
@MainActor
class ArgusRemoteWebUIDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func denyDisplayCapture(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        frame: WKFrameInfo,
        withSystemAudio: Bool,
        decisionHandler: @escaping (Int) -> Void
    ) {
        decisionHandler(0)
    }
}

enum ArgusBrowserDownloads {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    static func safeFilename(_ suggestedFilename: String) -> String {
        let leaf = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = leaf.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "download" : cleaned
    }

}

@MainActor
private final class BrowserDownloadDestinationRegistry {
    static let shared = BrowserDownloadDestinationRegistry()
    private var reservedPaths: Set<String> = []

    func reserve(filename: String, in directory: URL,
                 fileManager: FileManager) -> URL {
        let safe = ArgusBrowserDownloads.safeFilename(filename)
        let extensionName = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(safe, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path)
                || reservedPaths.contains(candidate.path) {
            let next = extensionName.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(extensionName)"
            candidate = directory.appendingPathComponent(next, isDirectory: false)
            suffix += 1
        }
        reservedPaths.insert(candidate.path)
        return candidate
    }

    func release(_ destination: URL) {
        reservedPaths.remove(destination.path)
    }
}

/// Owns WebKit's native download handoff for one browser tab. Downloads stay in
/// the authenticated WKWebView session (including POST, blob, and cookie-backed
/// responses), while only their completed bytes cross into the Mac Downloads
/// directory. The delegate never re-fetches a URL outside WebKit.
@MainActor
final class BrowserDownloadHandler: NSObject, WKDownloadDelegate {
    /// WKDownload's delegate is weak. Retain the handler independently of the
    /// originating tab until every transfer finishes so closing a page does not
    /// cancel or orphan a download that WebKit has already handed off.
    private static var activeHandlers: [ObjectIdentifier: BrowserDownloadHandler] = [:]

    private struct Transfer {
        let id: UUID
        let destination: URL
    }

    private weak var tab: DashboardTab?
    private let directory: URL
    private let fileManager: FileManager
    private let reservations = BrowserDownloadDestinationRegistry.shared
    private var transfers: [ObjectIdentifier: Transfer] = [:]

    init(tab: DashboardTab, directory: URL, fileManager: FileManager = .default) {
        self.tab = tab
        self.directory = directory
        self.fileManager = fileManager
    }

    func attach(_ download: WKDownload) {
        Self.activeHandlers[ObjectIdentifier(download)] = self
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = reservations.reserve(
                filename: suggestedFilename, in: directory, fileManager: fileManager
            )
            let transfer = Transfer(id: UUID(), destination: destination)
            transfers[ObjectIdentifier(download)] = transfer
            tab?.beginDownload(
                id: transfer.id,
                filename: destination.lastPathComponent,
                fileURL: destination,
                sourceURL: download.originalRequest?.url ?? response.url
            )
            completionHandler(destination)
        } catch {
            Self.activeHandlers.removeValue(forKey: ObjectIdentifier(download))
            let id = UUID()
            let destination = directory.appendingPathComponent(
                ArgusBrowserDownloads.safeFilename(suggestedFilename), isDirectory: false
            )
            tab?.beginDownload(id: id, filename: destination.lastPathComponent,
                               fileURL: destination,
                               sourceURL: download.originalRequest?.url ?? response.url)
            tab?.failDownload(id: id, error: error.localizedDescription)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        defer { Self.activeHandlers.removeValue(forKey: key) }
        guard let transfer = transfers.removeValue(forKey: key) else { return }
        reservations.release(transfer.destination)
        tab?.finishDownload(id: transfer.id)
    }

    func download(_ download: WKDownload, didFailWithError error: Error,
                  resumeData: Data?) {
        let key = ObjectIdentifier(download)
        defer { Self.activeHandlers.removeValue(forKey: key) }
        guard let transfer = transfers.removeValue(forKey: key) else { return }
        reservations.release(transfer.destination)
        tab?.failDownload(id: transfer.id, error: error.localizedDescription)
    }
}

enum ArgusBrowserNavigationPolicy {
    static func action(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        action.shouldPerformDownload ? .download : .allow
    }

    static func response(_ response: WKNavigationResponse) -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        return shouldDownload(canShowMIMEType: response.canShowMIMEType,
                              contentDisposition: disposition) ? .download : .allow
    }

    static func shouldDownload(canShowMIMEType: Bool,
                               contentDisposition: String?) -> Bool {
        let disposition = contentDisposition?.lowercased()
            .split(separator: ";", maxSplits: 1).first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return disposition == "attachment" || !canShowMIMEType
    }
}
