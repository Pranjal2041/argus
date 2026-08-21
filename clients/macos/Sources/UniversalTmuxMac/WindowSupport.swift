import AppKit
import SwiftUI

/// SwiftUI gives auxiliary `Window` scenes the `.fullScreenAuxiliary` collection
/// behavior, so their green button only *zooms* and "Enter Full Screen" is greyed
/// out. This flips the host NSWindow to `.fullScreenPrimary` so the secondary
/// windows (Files, Dashboards, Ports) get real native full screen like the main one.
final class FullScreenEnablerView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        refresh()
    }

    deinit { removeObservers() }

    /// SwiftUI can restore `.fullScreenAuxiliary` after this representable first
    /// attaches (notably when a persisted WKWebView is adopted into Dashboards).
    /// Reassert on view updates and whenever the host becomes active/key.
    func refresh() {
        apply()
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func observeWindow() {
        removeObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func apply() {
        guard let w = window else { return }
        w.styleMask.insert(.resizable)                       // green-button full screen needs this
        w.collectionBehavior.remove(.fullScreenAuxiliary)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.standardWindowButton(.zoomButton)?.isEnabled = true
    }
}

private struct FullScreenEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FullScreenEnablerView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FullScreenEnablerView)?.refresh()
    }
}

extension View {
    /// Allow this window to enter native full screen (for auxiliary `Window` scenes).
    func allowsFullScreen() -> some View { background(FullScreenEnabler()) }
}
