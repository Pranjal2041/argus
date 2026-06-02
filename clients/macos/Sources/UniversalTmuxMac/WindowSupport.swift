import AppKit
import SwiftUI

/// SwiftUI gives auxiliary `Window` scenes the `.fullScreenAuxiliary` collection
/// behavior, so their green button only *zooms* and "Enter Full Screen" is greyed
/// out. This flips the host NSWindow to `.fullScreenPrimary` so the secondary
/// windows (Files, Dashboards, Ports) get real native full screen like the main one.
private final class FullScreenEnablerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        // Re-apply after SwiftUI finishes configuring the window this cycle — a
        // one-shot set is otherwise overridden by SwiftUI's own window setup.
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }
    private func apply() {
        guard let w = window else { return }
        w.styleMask.insert(.resizable)                       // green-button full screen needs this
        w.collectionBehavior.remove(.fullScreenAuxiliary)
        w.collectionBehavior.insert(.fullScreenPrimary)
    }
}

private struct FullScreenEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FullScreenEnablerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Allow this window to enter native full screen (for auxiliary `Window` scenes).
    func allowsFullScreen() -> some View { background(FullScreenEnabler()) }
}
