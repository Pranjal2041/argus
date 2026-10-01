import BackgroundTasks
import SwiftUI
import UserNotifications

// MARK: Theme

@MainActor
final class ThemeStore: ObservableObject {
    static let key = "argus.themeId"
    @Published var palette: ThemePalette {
        didSet { UserDefaults.standard.set(palette.id, forKey: Self.key) }
    }
    init() {
        let id = UserDefaults.standard.string(forKey: Self.key)
        palette = ThemePalette.all.first { $0.id == id } ?? .argus
    }
}

// MARK: Notifications

/// Local notifications, as on Android: a session that ENTERS "waiting" while
/// you're not looking at it, and each new Lab access/approval request. Tapping
/// one opens the session or the Lab decision.
@MainActor
final class AttentionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotifications()
    static let enabledKey = "argus.notifications"
    private static let labNotifiedKey = "argus.lab.notified.v1"

    private weak var fleet: FleetStore?
    private weak var lab: LabStore?
    private weak var router: AppRouter?
    /// The terminal currently on screen ("machineID session"), never notified.
    var visibleSessionKey: String?
    private var labObservation: Task<Void, Never>?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); if newValue { requestAuthorization() } }
    }

    func attach(fleet: FleetStore, lab: LabStore, router: AppRouter) {
        self.fleet = fleet; self.lab = lab; self.router = router
        UNUserNotificationCenter.current().delegate = self
        if enabled { requestAuthorization() }
        fleet.onEnteredWaiting = { [weak self] entered in
            for (m, s) in entered { self?.notifyWaiting(machine: m, session: s) }
        }
        labObservation = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncLabNotifications()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyWaiting(machine m: Machine, session s: SessionInfo) {
        let key = FleetStore.key(m, s)
        guard enabled, key != visibleSessionKey else { return }
        let c = UNMutableNotificationContent()
        c.title = s.name
        c.body = "Agent is waiting on you — \(m.name)"
        c.sound = .default
        c.threadIdentifier = "sessions"
        c.userInfo = ["machineID": m.id, "session": s.name]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "session." + key, content: c, trigger: nil))
    }

    func clearSession(_ m: Machine, _ s: SessionInfo) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["session." + FleetStore.key(m, s)])
    }

    /// Lab items notify once per target (persisted), and clear when resolved.
    private func syncLabNotifications() {
        guard let lab else { return }
        var notified = UserDefaults.standard.stringArray(forKey: Self.labNotifiedKey) ?? []
        let live = Set(lab.attention.map(\.id))
        for item in lab.attention where !notified.contains(item.id) {
            notified.append(item.id)
            guard enabled else { continue }
            let c = UNMutableNotificationContent()
            c.title = (item.kind == .key ? "Lab access request · " : "Lab experiment approval · ") + item.reference
            c.body = "\(item.project) on \(item.machineName): \(item.summary)"
            c.sound = .default
            c.threadIdentifier = "lab"
            c.userInfo = ["labID": item.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lab." + item.id, content: c, trigger: nil))
        }
        let resolved = notified.filter { !live.contains($0) }
        if !resolved.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: resolved.map { "lab." + $0 })
        }
        UserDefaults.standard.set(Array(notified.suffix(1000)), forKey: Self.labNotifiedKey)
        updateBadge()
    }

    func updateBadge() {
        let n = (fleet?.needsAttention.count ?? 0) + (lab?.attention.count ?? 0)
        UNUserNotificationCenter.current().setBadgeCount(enabled ? n : 0)
    }

    func clearBadgeIfNeeded() { updateBadge() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let machineID = info["machineID"] as? String, session = info["session"] as? String, labID = info["labID"] as? String
        Task { @MainActor in
            if let labID, let item = self.lab?.attention.first(where: { $0.id == labID }) {
                self.router?.openLab(item)
            } else if let machineID, let session, let fleet = self.fleet, let m = fleet.machine(id: machineID),
                      let s = fleet.session(on: m, named: session) {
                self.router?.tab = .commandCenter
                self.router?.openTerminal(m, s)
            }
            completionHandler()
        }
    }
}

// MARK: Background refresh

/// iOS does not let apps poll continuously in the background. When the system
/// grants a refresh window, check every known broker once and notify sessions
/// that started waiting since the app was last active.
enum BackgroundRefresh {
    static let identifier = "dev.universaltmux.ios.refresh"
    private static let machinesKey = "argus.bg.machines"
    private static let statesKey = "argus.bg.states"

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    /// Remembered by the foreground app so the background check needs no discovery.
    @MainActor static func remember(_ fleet: FleetStore) {
        let entries = fleet.machines.map { [$0.id, $0.name, $0.httpBase.absoluteString] }
        UserDefaults.standard.set(entries, forKey: machinesKey)
        var states: [String: String] = [:]
        for m in fleet.machines { for s in fleet.allSessions[m.id] ?? [] where s.isForeground { states[m.id + " " + s.name] = s.state ?? "" } }
        UserDefaults.standard.set(states, forKey: statesKey)
    }

    static func run() async {
        schedule()
        guard AttentionNotificationsEnabled.value else { return }
        let entries = UserDefaults.standard.array(forKey: machinesKey) as? [[String]] ?? []
        var states = UserDefaults.standard.dictionary(forKey: statesKey) as? [String: String] ?? [:]
        struct R: Decodable { let sessions: [SessionInfo] }
        for e in entries where e.count == 3 {
            guard let base = URL(string: e[2]),
                  let r = try? await BrokerHTTP.get(base, "sessions", as: R.self) else { continue }
            for s in r.sessions where s.isForeground {
                let key = e[0] + " " + s.name
                if s.state == "waiting", states[key] != "waiting" {
                    let c = UNMutableNotificationContent()
                    c.title = s.name
                    c.body = "Agent is waiting on you — \(e[1])"
                    c.sound = .default
                    c.userInfo = ["machineID": e[0], "session": s.name]
                    try? await UNUserNotificationCenter.current().add(
                        UNNotificationRequest(identifier: "session." + key, content: c, trigger: nil))
                }
                states[key] = s.state ?? ""
            }
        }
        UserDefaults.standard.set(states, forKey: statesKey)
    }
}

enum AttentionNotificationsEnabled {
    static var value: Bool { UserDefaults.standard.object(forKey: AttentionNotifications.enabledKey) as? Bool ?? true }
}
