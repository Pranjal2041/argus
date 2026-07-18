import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid
import IOKit.hidsystem

/// User-facing preferences for the optional hardware attention signal.
enum CapsLockAttentionPrefs {
    static let enabledKey = "ut.attention.capsLock.enabled"
    static let durationKey = "ut.attention.capsLock.duration"
    static let reminderMinutesKey = "ut.attention.capsLock.reminderMinutes"
    static let completionEnabledKey = "ut.attention.capsLock.completionEnabled"
    static let completionDurationKey = "ut.attention.capsLock.completionDuration"

    static let defaultDuration = 10.0
    static let defaultReminderMinutes = 5.0
    static let defaultCompletionDuration = 2.0

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    static var duration: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: durationKey) as? Double ?? defaultDuration
        return min(60, max(1, stored))
    }

    static var reminderInterval: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: reminderMinutesKey) as? Double
            ?? defaultReminderMinutes
        return min(30, max(1, minutes)) * 60
    }

    static var completionEnabled: Bool {
        UserDefaults.standard.object(forKey: completionEnabledKey) as? Bool ?? false
    }

    static var completionDuration: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: completionDurationKey) as? Double
            ?? defaultCompletionDuration
        return min(10, max(1, stored))
    }
}

enum AttentionBlinkAction: Equatable {
    case none
    case pulse
    case stop
}

/// Pure transition policy, split from timers and IOKit so entry/re-entry behavior
/// remains deterministic and unit-testable.
struct AttentionBlinkState {
    private(set) var ids: Set<String> = []
    private(set) var enabled = false

    mutating func update(ids newIDs: Set<String>, enabled newEnabled: Bool) -> AttentionBlinkAction {
        let oldIDs = ids
        let wasEnabled = enabled
        ids = newIDs
        enabled = newEnabled

        guard newEnabled else {
            return wasEnabled ? .stop : .none
        }
        guard !newIDs.isEmpty else {
            return oldIDs.isEmpty ? .none : .stop
        }
        if !wasEnabled || !newIDs.subtracting(oldIDs).isEmpty {
            return .pulse
        }
        return .none
    }
}

enum CapsLockInputAccess: Equatable {
    case notDetermined
    case denied
    case granted
}

func capsLockInputAccess(from access: IOHIDAccessType) -> CapsLockInputAccess {
    switch access {
    case kIOHIDAccessTypeGranted: return .granted
    case kIOHIDAccessTypeDenied: return .denied
    default: return .notDetermined
    }
}

func shouldStartCompletionPulse(enabled: Bool, transitionIDs: Set<String>,
                                needsYouPending: Bool) -> Bool {
    enabled && !transitionIDs.isEmpty && !needsYouPending
}

/// The completion light mirrors the user-facing fleet, not housekeeping work.
/// Keeping this policy pure makes the exact Working -> Idle boundary testable.
func isVisibleWorkingToIdleTransition(previous: String?, current: String,
                                      isAgentSession: Bool, isHidden: Bool,
                                      isBacklogged: Bool) -> Bool {
    previous == "working"
        && current == "idle"
        && !isAgentSession
        && !isHidden
        && !isBacklogged
}

/// Direct HID output driver for the Caps Lock LED. It writes the keyboard's LED
/// element, never a Caps Lock key event, so the user's typing state is untouched.
/// All synchronous IOKit work lives on this actor instead of the app's main thread.
private actor CapsLockLEDHardware {
    private struct Target {
        let device: IOHIDDevice
        let element: IOHIDElement
    }

    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var targets: [Target] = []
    private var generation: UInt64 = 0

    /// Blink for `duration`, returning how many physical/virtual keyboard LED
    /// elements accepted targeting. A generation token prevents an older,
    /// cancelled burst from overwriting a newer burst's final LED state.
    func blink(duration: TimeInterval, phase: TimeInterval = 0.25) async -> Int {
        generation &+= 1
        let token = generation
        restoreAndClose()
        discoverTargets()
        guard !targets.isEmpty else {
            restoreAndClose()
            return 0
        }

        let original = logicalCapsLockOn()
        let steps = max(1, Int(ceil(duration / phase)))
        var acceptedCount = 0
        for step in 0..<steps {
            guard token == generation, !Task.isCancelled else { break }
            // Start with the opposite of the real state, making the first phase
            // visible whether Caps Lock was originally on or off.
            acceptedCount = max(
                acceptedCount,
                setLED(step.isMultiple(of: 2) ? !original : original))
            do {
                try await Task.sleep(nanoseconds: UInt64(phase * 1_000_000_000))
            } catch {
                break
            }
        }

        if token == generation {
            restoreAndClose()
        }
        return acceptedCount
    }

    func stop() {
        generation &+= 1
        restoreAndClose()
    }

    private func logicalCapsLockOn() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }

    @discardableResult
    private func setLED(_ on: Bool) -> Int {
        var acceptedCount = 0
        for target in targets {
            let value = IOHIDValueCreateWithIntegerValue(
                kCFAllocatorDefault, target.element, mach_absolute_time(), on ? 1 : 0)
            if IOHIDDeviceSetValue(target.device, target.element, value) == kIOReturnSuccess {
                acceptedCount += 1
            }
        }
        return acceptedCount
    }

    private func restoreAndClose() {
        if !targets.isEmpty {
            setLED(logicalCapsLockOn())
        }
        targets.removeAll()
        for device in devices {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        devices.removeAll()
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    private func discoverTargets() {
        let hidManager = IOHIDManagerCreate(
            kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboardMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: Int(kHIDPage_GenericDesktop),
            kIOHIDDeviceUsageKey as String: Int(kHIDUsage_GD_Keyboard),
        ]
        IOHIDManagerSetDeviceMatching(hidManager, keyboardMatch as CFDictionary)
        guard IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
                == kIOReturnSuccess else {
            return
        }
        manager = hidManager

        let ledMatch: [String: Any] = [
            kIOHIDElementUsagePageKey as String: Int(kHIDPage_LEDs),
            kIOHIDElementUsageKey as String: Int(kHIDUsage_LED_CapsLock),
        ]
        for device in (IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice>) ?? [] {
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
                    == kIOReturnSuccess else { continue }
            let elements = IOHIDDeviceCopyMatchingElements(
                device, ledMatch as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone))
                as? [IOHIDElement] ?? []
            guard !elements.isEmpty else {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                continue
            }
            devices.append(device)
            targets.append(contentsOf: elements.map { Target(device: device, element: $0) })
        }
    }
}

/// Schedules Caps Lock LED bursts for Needs You and Working -> Idle events.
/// Needs You repeats; completion is a separate, one-shot signal.
@MainActor
final class CapsLockAttentionController: ObservableObject {
    static let shared = CapsLockAttentionController()

    @Published private(set) var lastTargetCount: Int?
    @Published private(set) var inputAccess: CapsLockInputAccess

    private let hardware = CapsLockLEDHardware()
    private var state = AttentionBlinkState()
    private var blinkTask: Task<Void, Never>?
    private var reminderTimer: Timer?

    private init() {
        inputAccess = AppState.isRunningTests ? .notDetermined : Self.currentInputAccess()
    }

    private static func currentInputAccess() -> CapsLockInputAccess {
        capsLockInputAccess(from: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
    }

    func refreshInputAccess() {
        guard !AppState.isRunningTests else { return }
        inputAccess = Self.currentInputAccess()
        if inputAccess != .granted { lastTargetCount = nil }
    }

    /// Ask once when access has never been decided. A denial must be changed in
    /// System Settings, so subsequent clicks open the exact privacy pane.
    func resolveInputAccess() {
        guard !AppState.isRunningTests else { return }
        refreshInputAccess()
        if inputAccess == .notDetermined {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            refreshInputAccess()
        } else if inputAccess == .denied,
                  let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func update(needsYouIDs: Set<String>) {
        guard !AppState.isRunningTests else { return }
        apply(state.update(ids: needsYouIDs, enabled: CapsLockAttentionPrefs.enabled))
    }

    /// Called by Settings for both toggle and timing changes. Enabling while
    /// attention is already pending produces an immediate burst.
    func configurationDidChange() {
        guard !AppState.isRunningTests else { return }
        let action = state.update(ids: state.ids, enabled: CapsLockAttentionPrefs.enabled)
        apply(action)
        if action == .none {
            scheduleReminder()
        }
    }

    /// Called once for each refresh batch containing at least one visible panel
    /// that moved directly from Working to Idle. Never interrupts Needs You.
    func workingBecameIdle(ids: Set<String>) {
        guard !AppState.isRunningTests else { return }
        let needsYouPending = state.enabled && !state.ids.isEmpty
        guard shouldStartCompletionPulse(
            enabled: CapsLockAttentionPrefs.completionEnabled,
            transitionIDs: ids,
            needsYouPending: needsYouPending) else { return }
        startBlink(duration: CapsLockAttentionPrefs.completionDuration)
    }

    /// A short hardware check that works even while the feature is disabled.
    func testBlink() {
        guard !AppState.isRunningTests else { return }
        guard ensureInputAccess(promptIfNeeded: true) else { return }
        startBlink(duration: min(2, CapsLockAttentionPrefs.duration))
    }

    private func ensureInputAccess(promptIfNeeded: Bool = false) -> Bool {
        refreshInputAccess()
        if inputAccess == .notDetermined, promptIfNeeded {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            refreshInputAccess()
        }
        return inputAccess == .granted
    }

    private func apply(_ action: AttentionBlinkAction) {
        switch action {
        case .none:
            break
        case .pulse:
            startBlink(duration: CapsLockAttentionPrefs.duration)
            scheduleReminder()
        case .stop:
            reminderTimer?.invalidate()
            reminderTimer = nil
            blinkTask?.cancel()
            blinkTask = nil
            Task { await hardware.stop() }
        }
    }

    private func startBlink(duration: TimeInterval) {
        guard ensureInputAccess() else { return }
        blinkTask?.cancel()
        blinkTask = Task { [weak self, hardware] in
            let count = await hardware.blink(duration: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lastTargetCount = count }
        }
    }

    private func scheduleReminder() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        guard state.enabled, !state.ids.isEmpty else { return }
        let timer = Timer(timeInterval: CapsLockAttentionPrefs.reminderInterval,
                          repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.enabled, !self.state.ids.isEmpty else { return }
                self.startBlink(duration: CapsLockAttentionPrefs.duration)
            }
        }
        reminderTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
