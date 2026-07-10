import AppKit
import SwiftUI
import UserNotifications

/// On/off pref for attention notifications (banner + Dock badge).
enum NotifyPrefs {
    static let enabledKey = "ut.notify.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
}

/// Closes the attention loop: a banner when a session transitions INTO "waiting"
/// (an agent is blocked on you) + a Dock-tile badge with the total waiting count.
/// Additive — reads AppState, never mutates its session/selection model except to
/// deep-link a tapped banner. Singleton so the notification-center delegate and
/// the SwiftUI app share one instance.
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotifier()
    private weak var state: AppState?
    private var asked = false
    private override init() { super.init() }

    func attach(_ s: AppState) {
        state = s
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard NotifyPrefs.enabled, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Post a banner for each session that just entered "waiting"; reflect the
    /// total waiting count on the Dock tile.
    func update(enteredWaiting: [(ref: SessionRef, machine: String)], totalWaiting: Int) {
        NSApp.dockTile.badgeLabel = (NotifyPrefs.enabled && totalWaiting > 0) ? String(totalWaiting) : nil
        guard NotifyPrefs.enabled else { return }
        let center = UNUserNotificationCenter.current()
        for e in enteredWaiting {
            let c = UNMutableNotificationContent()
            c.title = e.ref.session
            c.body = "\(e.ref.session) on \(e.machine) needs you"
            c.sound = .default
            c.userInfo = ["m": e.ref.machineID, "s": e.ref.session]
            center.add(UNNotificationRequest(identifier: "ut.attn." + e.ref.id, content: c, trigger: nil))
        }
    }

    func clearBadge() { NSApp.dockTile.badgeLabel = nil }

    /// Post a banner for a new Lab approval item (a pending key request or a
    /// gated run proposal). Tapping it opens the Lab pane.
    func labApprovalNeeded(id: String, title: String, body: String) {
        guard NotifyPrefs.enabled else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = ["lab": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ut.lab." + id, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let u = response.notification.request.content.userInfo
        if u["lab"] as? Bool == true {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                guard let st = self.state else { return }
                st.showLab = true
                st.showOverview = false; st.showTodos = false; st.showNotes = false; st.showLedger = false
            }
            completionHandler()
            return
        }
        if let m = u["m"] as? String, let s = u["s"] as? String {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                self.state?.selection = SessionRef(machineID: m, session: s)
            }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
