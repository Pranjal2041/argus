// Compile alongside the production MainActorRuntime.swift. Run with either
// "dispatch" or "run-loop" to check both executor implementations in isolation.
import Foundation

@main
struct RuntimeCheck {
    @MainActor static var observations = 0
    @MainActor static var observers: [NSObjectProtocol] = []
    @MainActor static var watchdog: MainActorWatchdog?

    static func main() {
        let mode = CommandLine.arguments.last ?? "run-loop"
        let center = NotificationCenter()
        let first = Notification.Name("runtime.first"), second = Notification.Name("runtime.second")
        // An independent timeout also catches a wedged main actor.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(2) }
        Task { @MainActor in
            if mode == "stalled" {
                watchdog = MainActorWatchdog(interval: 0.05, maximumMisses: 2) {
                    print("PASS stalled: independent watchdog detected the blocked main executor")
                    exit(0)
                }
                watchdog?.start()
                DispatchQueue.main.async { DispatchSemaphore(value: 0).wait() }
                return
            }
            observers.append(MainActorNotification.observe(first, center: center) {
                observations += 1
                center.post(name: second, object: nil)
            })
            observers.append(MainActorNotification.observe(second, center: center) {
                observations += 1
                if observations == 4 {
                    if mode == "run-loop" { precondition(Thread.isMainThread) }
                    print("PASS \(mode): main-actor and background posts, nested delivery, executor remained live")
                    exit(0)
                }
            })
            center.post(name: first, object: nil)
            DispatchQueue.global().async { center.post(name: first, object: nil) }
        }
        if mode == "dispatch" { dispatchMain() }
        HeadlessMainRunLoop.run()
    }
}
