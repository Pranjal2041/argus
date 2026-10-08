import Foundation

/// Notification delivery must never synchronously wait for its destination
/// executor. A main dispatch queue is not necessarily the process's main thread
/// (notably under dispatchMain), so OperationQueue.main can deadlock the poster.
enum MainActorNotification {
    static func observe(_ name: Notification.Name, center: NotificationCenter = .default,
                        action: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: nil) { _ in
            Task { @MainActor in action() }
        }
    }
}

/// Foundation services, distributed notifications, and the main actor share an
/// actual main-thread run loop even when this process has no application window.
enum HeadlessMainRunLoop {
    private static let watchdog = MainActorWatchdog()
    static func run() -> Never {
        precondition(Thread.isMainThread)
        watchdog.start()
        let keepAlive = Port()
        RunLoop.main.add(keepAlive, forMode: .default)
        while true { _ = RunLoop.main.run(mode: .default, before: .distantFuture) }
    }
}

struct MainActorHealth {
    enum Action { case probe, wait, stalled }
    var maximumMisses = 4
    private(set) var pending = false
    private(set) var misses = 0

    mutating func check() -> Action {
        guard pending else { pending = true; return .probe }
        misses += 1
        return misses >= maximumMisses ? .stalled : .wait
    }

    mutating func acknowledge() { pending = false; misses = 0 }
}

/// launchd can restart an exited worker, not a living but deadlocked one. Probe
/// the executor from an independent queue, with at most one probe outstanding.
/// Count delivered timer ticks rather than elapsed wall time: sleep itself is
/// not a failed heartbeat and must never trigger a restart on wake.
final class MainActorWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "argus.runtime.watchdog", qos: .utility)
    private let interval: TimeInterval
    private let stalled: @Sendable () -> Void
    private var health: MainActorHealth
    private var timer: DispatchSourceTimer?

    init(interval: TimeInterval = 15, maximumMisses: Int = 4,
         stalled: @escaping @Sendable () -> Void = {
             NSLog("[workspace-service] Main executor stopped responding; restarting collector.")
             exit(75)
         }) {
        self.interval = interval
        self.health = MainActorHealth(maximumMisses: maximumMisses)
        self.stalled = stalled
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.check() }
            self.timer = timer
            timer.resume()
        }
    }

    private func check() {
        switch health.check() {
        case .wait: break
        case .stalled:
            timer?.cancel(); timer = nil
            stalled()
        case .probe:
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queue.async { [self] in self.health.acknowledge() }
            }
        }
    }

    deinit { timer?.cancel() }
}
