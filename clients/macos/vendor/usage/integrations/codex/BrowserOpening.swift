import AppKit
import Foundation

protocol BrowserOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

/// User-facing app links follow the macOS default browser. No agent browser dependency.
struct DefaultBrowserOpener: BrowserOpening {
    var launch: @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    func open(_ url: URL) async -> Bool { await launch(url) }
}
