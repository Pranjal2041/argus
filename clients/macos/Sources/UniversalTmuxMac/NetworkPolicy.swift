import AppKit
import Foundation
import Network
import SwiftUI

/// One device-local budget for automatic work in both the GUI and collector.
/// Explicit user actions bypass cadence limits, never transport ownership limits.
struct NetworkPolicy: Equatable {
    var lowData = false
    /// Keep a small recent set ready for a quick return, with a hard traffic
    /// budget even if a hidden terminal is producing output continuously.
    var warmTerminalLimit: Int { lowData ? 3 : 8 }
    var terminalRetention: BrokerBackgroundRetention { .init(grace: 60, byteLimit: 64 * 1024) }
    var foregroundSessions: TimeInterval { lowData ? 10 : 2 }
    var backgroundSessions: TimeInterval { lowData ? 60 : 2 }
    var fullSessions: TimeInterval { lowData ? 120 : 30 }
    var discovery: TimeInterval { lowData ? 120 : 12 }
    var workspaceSync: TimeInterval { lowData ? 30 : 6 }
    var history: TimeInterval { lowData ? 300 : 30 }
    var userDataSync: TimeInterval { lowData ? 60 : 10 }
    var collectorSessions: TimeInterval { lowData ? 60 : 5 }
    var commandCenter: TimeInterval { lowData ? 60 : 5 }
    var commandCenterContent: TimeInterval { lowData ? 60 : 30 }
    var journal: TimeInterval { lowData ? 300 : 30 }
    var wrapped: TimeInterval { lowData ? 1800 : 300 }
    func usage(_ configured: TimeInterval) -> TimeInterval { lowData ? max(600, configured) : configured }
    func lab(visible: Bool) -> TimeInterval { lowData ? (visible ? 15 : 120) : (visible ? 5 : 20) }
}

/// Uses monotonic time and the CURRENT interval, so toggling the mode cannot
/// leave old timers running at their previous rate. Separate keys stay independent.
struct NetworkCadence {
    private var last: [String: TimeInterval] = [:]
    mutating func due(_ key: String, every interval: TimeInterval, force: Bool = false,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard force || (last[key].map({ now - $0 >= interval }) ?? true) else { return false }
        last[key] = now
        return true
    }
    mutating func reset() { last.removeAll() }
}

enum NetworkPreferences {
    static let lowDataKey = "ut.network.lowData"
    static let changed = Notification.Name("dev.universaltmux.network-policy-changed")
    static var policy: NetworkPolicy { NetworkPolicy(lowData: UserDefaults.standard.bool(forKey: lowDataKey)) }

    static func setLowData(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: lowDataKey)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: changed, object: nil)
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// Recovery is driven by a changed route/wake, not by faster blind retries.
/// Every broker uses the same signal; it carries no provider or host exceptions.
final class BrokerNetworkRecovery {
    static let shared = BrokerNetworkRecovery()
    static let recovered = Notification.Name("dev.universaltmux.network-recovered")
    private let monitor = NWPathMonitor()
    private var receivedInitialPath = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                // NWPath reports route changes within the same interface type
                // too. Comparing only "Wi-Fi, satisfied" misses those recoveries.
                let initial = !self.receivedInitialPath
                self.receivedInitialPath = true
                if !initial, path.status == .satisfied {
                    NotificationCenter.default.post(name: Self.recovered, object: nil)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "argus.network-path"))
        observers.append(MainActorNotification.observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) {
            NotificationCenter.default.post(name: Self.recovered, object: nil)
        })
        observers.append(MainActorNotification.observe(NetworkPreferences.changed, center: DistributedNotificationCenter.default()) {
            UserDefaults.standard.synchronize()
            NotificationCenter.default.post(name: NetworkPreferences.changed, object: nil)
        })
    }
}

struct NetworkSettingsSection: View {
    @AppStorage private var lowData: Bool
    private let changed: (Bool) -> Void
    init(defaults: UserDefaults = .standard, changed: @escaping (Bool) -> Void = NetworkPreferences.setLowData) {
        _lowData = AppStorage(wrappedValue: false, NetworkPreferences.lowDataKey, store: defaults)
        self.changed = changed
    }
    var body: some View {
        Section {
            Toggle("Low Data Mode", isOn: $lowData)
                .accessibilityIdentifier("low-data-mode")
                .onChange(of: lowData, perform: changed)
        } header: {
            Text("Network")
        } footer: {
            Text("Recent terminals stay ready for quick switching, with time and data limits on hidden panes. Background lists, summaries, and usage refresh less often. Remote jobs keep running.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
