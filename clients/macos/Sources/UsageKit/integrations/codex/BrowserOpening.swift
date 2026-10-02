import AppKit
import Foundation

@available(macOS 14.0, *)
protocol BrowserOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

/// The host supplies its own browser. Authentication never silently launches a
/// different browser when the host integration is unavailable.
@available(macOS 14.0, *)
struct DefaultBrowserOpener: BrowserOpening {
    var launch: @MainActor @Sendable (URL) -> Bool = { UsageBrowser.open($0) }
    func open(_ url: URL) async -> Bool { await launch(url) }
}
