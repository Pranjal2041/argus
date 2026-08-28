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
