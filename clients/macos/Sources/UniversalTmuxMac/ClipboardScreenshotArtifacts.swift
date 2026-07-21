import AppKit
import Combine
import Foundation

enum ClipboardScreenshotArtifactPrefs {
    static let enabledKey = "ut.artifacts.captureForegroundClipboardScreenshots"
    static let defaultEnabled = true
}

enum ArgusWindowIdentity {
    static let main = NSUserInterfaceItemIdentifier("Argus.MainWindow")
}

/// A tiny, testable edge detector. Every pasteboard generation is consumed
/// exactly once, including ineligible ones, so an image copied while Argus is
/// inactive can never be imported later when the app returns to the foreground.
struct ForegroundClipboardChangeGate {
    private(set) var observedChangeCount: Int

    init(changeCount: Int) {
        observedChangeCount = changeCount
    }

    mutating func reset(changeCount: Int) {
        observedChangeCount = changeCount
    }

    mutating func consume(changeCount: Int, eligible: Bool) -> Bool {
        guard changeCount != observedChangeCount else { return false }
        observedChangeCount = changeCount
        return eligible
    }
}

/// Imports a newly-created clipboard image only while the main Argus workspace
/// is the foreground window and a real panel is visible. Normal polling reads
/// one pasteboard integer twice per second; image bytes are touched only after
/// that integer changes. No keyboard hooks, filesystem watchers, or additional
/// macOS permissions are used.
@MainActor
final class ClipboardScreenshotArtifactMonitor: NSObject, ObservableObject {
    private weak var state: AppState?
    private weak var notebooks: NotebooksModel?
    private weak var artifacts: ArtifactStore?
    private var gate = ForegroundClipboardChangeGate(
        changeCount: NSPasteboard.general.changeCount
    )
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var contextCancellables: Set<AnyCancellable> = []
    private var enabled = ClipboardScreenshotArtifactPrefs.defaultEnabled

    func bind(
        state: AppState,
        notebooks: NotebooksModel,
        artifacts: ArtifactStore,
        enabled: Bool
    ) {
        self.state = state
        self.notebooks = notebooks
        self.artifacts = artifacts
        self.enabled = enabled
        installObserversOnce()
        installContextFlushes(state: state, notebooks: notebooks)
        baselineAndReconcile()
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        baselineAndReconcile()
    }

    private func installObserversOnce() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.baselineAndReconcile() }
        })
        observers.append(center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flushAndStop() }
        })
    }

    /// `@Published` emits before the value changes. Flush at that boundary so
    /// a screenshot followed immediately by a panel switch is still attributed
    /// to the panel that was actually visible, not the destination panel.
    private func installContextFlushes(state: AppState, notebooks: NotebooksModel) {
        guard contextCancellables.isEmpty else { return }
        let stateChanges: [AnyPublisher<Void, Never>] = [
            state.$selection.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            state.$showOverview.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            state.$showTodos.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            state.$showNotes.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            state.$showLedger.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            state.$showLab.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            state.$showArtifacts.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            notebooks.$activeID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        for publisher in stateChanges {
            publisher.sink { [weak self] _ in self?.poll() }
                .store(in: &contextCancellables)
        }
    }

    private func baselineAndReconcile() {
        gate.reset(changeCount: NSPasteboard.general.changeCount)
        if enabled && NSApp.isActive {
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func stopAndBaseline() {
        stopTimer()
        gate.reset(changeCount: NSPasteboard.general.changeCount)
    }

    private func flushAndStop() {
        poll()
        stopAndBaseline()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let context = currentPanelContext()
        guard gate.consume(
            changeCount: pasteboard.changeCount,
            eligible: context != nil
        ), let context, let png = clipboardImagePNG() else { return }

        Task {
            do {
                _ = try await artifacts?.saveScreenshotPNG(png, panel: context)
            } catch {
                artifacts?.errorMessage = "Screenshot artifact could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private func currentPanelContext() -> ArtifactPanelContext? {
        guard enabled,
              NSApp.isActive,
              NSApp.keyWindow?.identifier == ArgusWindowIdentity.main,
              let state,
              notebooks?.activeID == nil,
              !state.showOverview,
              !state.showTodos,
              !state.showNotes,
              !state.showLedger,
              !state.showLab,
              !state.showArtifacts,
              let ref = state.selection
        else { return nil }
        return state.artifactContext(for: ref)
    }

    deinit {
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
