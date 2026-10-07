import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

final class NetworkPolicyTests: XCTestCase {
    func testLowDataBudgetsReduceBothInteractiveAndCollectorTraffic() {
        let normal = NetworkPolicy(), low = NetworkPolicy(lowData: true)
        XCTAssertEqual(low.foregroundSessions, 10)
        XCTAssertEqual(low.backgroundSessions, 60)
        XCTAssertEqual(low.collectorSessions, 60)
        XCTAssertGreaterThan(low.discovery, normal.discovery)
        XCTAssertGreaterThan(low.workspaceSync, normal.workspaceSync)
        XCTAssertGreaterThan(low.history, normal.history)
        XCTAssertGreaterThan(low.userDataSync, normal.userDataSync)
        XCTAssertGreaterThan(low.commandCenter, normal.commandCenter)
        XCTAssertGreaterThan(low.journal, normal.journal)
        XCTAssertGreaterThan(low.wrapped, normal.wrapped)
        XCTAssertEqual(low.usage(120), 600)
        XCTAssertEqual(low.usage(1800), 1800)
        XCTAssertGreaterThan(low.lab(visible: false), low.lab(visible: true))
    }

    func testCadenceAdaptsImmediatelyAndExplicitWorkBypassesOnlyTheTimer() {
        var cadence = NetworkCadence()
        XCTAssertTrue(cadence.due("sessions", every: 2, now: 0))
        XCTAssertFalse(cadence.due("sessions", every: 60, now: 2))
        XCTAssertFalse(cadence.due("sessions", every: 60, now: 59))
        XCTAssertTrue(cadence.due("sessions", every: 60, force: true, now: 59))
        XCTAssertFalse(cadence.due("sessions", every: 60, now: 60))
        XCTAssertTrue(cadence.due("sessions", every: 2, now: 61))
        XCTAssertTrue(cadence.due("usage", every: 600, now: 61))
        cadence.reset()
        XCTAssertTrue(cadence.due("sessions", every: 60, now: 62))
    }

    @MainActor func testCollectorJobChangingBudgetDoesNotKeepOldFastScheduleOrOverlap() async {
        let job = WorkspaceRecurringJob(interval: 5)
        let now = Date(), completed = expectation(description: "first job completed")
        XCTAssertTrue(job.runIfDue(now: now) { completed.fulfill() })
        await fulfillment(of: [completed], timeout: 1)
        await Task.yield()
        XCTAssertFalse(job.runIfDue(now: now.addingTimeInterval(5), intervalOverride: 60) { XCTFail("old cadence") })
        let second = expectation(description: "normal cadence restored")
        XCTAssertTrue(job.runIfDue(now: now.addingTimeInterval(6)) { second.fulfill() })
        await fulfillment(of: [second], timeout: 1)
    }

    @MainActor func testActualLowDataToggleRendersPersistsAndUpdatesTerminalPolicy() async throws {
        guard ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let suite = "network-settings-test-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let harness = BrokerClientHarness()
        let connection = PaneConn(url: harness.url, traceRef: "settings-hidden", client: harness.client)
        defer { connection.disconnect() }
        connection.setVisible(false)
        var changed: [Bool] = []
        let host = NSHostingView(rootView: Form {
            NetworkSettingsSection(defaults: defaults) { enabled in
                changed.append(enabled)
                connection.applyNetworkPolicy(.init(lowData: enabled), appActive: true)
            }
        }.formStyle(.grouped).frame(width: 460, height: 250))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 250)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.transports.count, 1)
        for enabled in [true, false] {
            XCTAssertTrue(press(host, "low-data-mode"))
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(defaults.bool(forKey: NetworkPreferences.lowDataKey), enabled)
            XCTAssertEqual(changed.last, enabled)
            if enabled { XCTAssertTrue(harness.transports[0].invalidated) }
            else { XCTAssertEqual(harness.transports.count, 2) }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-low-data-\(enabled ? "on" : "off").png"))
        }
    }

    @MainActor private func press(_ element: Any, _ identifier: String, depth: Int = 0) -> Bool {
        guard depth < 40, let node = element as? NSObject else { return false }
        let ids = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
        let found = node.responds(to: ids) ? node.perform(ids)?.takeUnretainedValue() as? String : nil
        if found == identifier {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard node.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            // SwiftUI dispatches this action even when its AX bridge returns
            // false. Assert the persisted value and transport effect above;
            // this result only reports whether the control was found/invoked.
            _ = unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
            return true
        }
        let values = node.responds(to: children) ? node.perform(children)?.takeUnretainedValue() as? [Any] : nil
        return (values ?? []).contains { press($0, identifier, depth: depth + 1) }
    }

    @MainActor func testSuspendedStatusRendersAsIntentionalPause() async throws {
        guard ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: HStack(spacing: 12) {
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
            Text("example-session").font(.system(size: 13, weight: .semibold))
            TerminalConnectionLabel(state: .suspended)
        }.padding(20).frame(width: 450, height: 70).background(Theme.appBackground))
        host.frame = NSRect(x: 0, y: 0, width: 450, height: 70)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-low-data-paused.png"))
    }
}

@MainActor
final class BrokerRecoveryTests: XCTestCase {
    func testSlowHandshakeGetsItsOwnDeadlineAndRevealDoesNotRestartIt() async throws {
        let harness = BrokerClientHarness(recovery: .init(handshakeTimeout: 0.5, firstFrameTimeout: 0.05))
        harness.onCreate = { $0.openDelay = 0.15; $0.firstFrame = true }
        harness.client.start()
        defer { harness.client.stop() }
        try await Task.sleep(for: .milliseconds(80))
        harness.client.nudge(trigger: "revealed")
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(harness.transports.count, 1)
        XCTAssertFalse(harness.transports[0].invalidated)
        XCTAssertEqual(harness.statuses.last, .connected)
    }

    func testOpenedButSilentSocketHasIndependentBoundedDeadline() async throws {
        let harness = BrokerClientHarness(recovery: .init(handshakeTimeout: 0.5, firstFrameTimeout: 0.05))
        harness.onCreate = { $0.openDelay = 0.01 }
        harness.client.start()
        defer { harness.client.stop() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(harness.transports[0].invalidated)
        XCTAssertEqual(harness.statuses.last, .reconnecting)
    }

    func testHandshakeTimeoutDoesNotDependOnCancelledReceiveCallback() async throws {
        let harness = BrokerClientHarness(recovery: .init(handshakeTimeout: 0.04))
        harness.client.start()
        defer { harness.client.stop() }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThanOrEqual(harness.transports.count, 2)
        XCTAssertTrue(harness.transports[0].invalidated)
    }

    func testEstablishedSilentSocketIsDetectedAndPongKeepsIdleSocketAlive() async throws {
        for pong in [false, true] {
            let harness = BrokerClientHarness(recovery: .init(heartbeatInterval: 0.04, heartbeatTimeout: 0.03))
            harness.onCreate = { $0.openDelay = 0.001; $0.firstFrame = true; $0.answersPings = pong }
            harness.client.start()
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertGreaterThan(harness.transports[0].pings, 0)
            XCTAssertEqual(harness.transports[0].invalidated, !pong)
            XCTAssertEqual(harness.statuses.last, pong ? .connected : .reconnecting)
            harness.client.stop()
        }
    }

    func testHeartbeatEvidenceBelongsToItsTransportNotTheNextRoute() async throws {
        let old = URL(string: "wss://old-\(UUID().uuidString).example:8722/ws")!
        let next = URL(string: "wss://next-\(UUID().uuidString).example:8722/ws")!
        let harness = BrokerClientHarness(url: old, recovery: .init(heartbeatInterval: 0.04, heartbeatTimeout: 0.03))
        harness.onCreate = { $0.openDelay = 0.001; $0.firstFrame = true; $0.answersPings = true }
        harness.client.start()
        defer { harness.client.stop() }
        try await Task.sleep(for: .milliseconds(20))
        harness.client.updateURL(next)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(harness.transports.count, 1)
        XCTAssertGreaterThan(harness.transports[0].pings, 0)
        XCTAssertNotNil(BrokerReachabilityEvidence.shared.latest(httpBase: old.absoluteString))
        XCTAssertNil(BrokerReachabilityEvidence.shared.latest(httpBase: next.absoluteString))
    }

    func testSuspensionCancelsRetryRejectsOldCallbacksAndResumesOnlyOnce() async throws {
        let harness = BrokerClientHarness()
        harness.client.start()
        try await Task.sleep(for: .milliseconds(20))
        let old = harness.transports[0]
        harness.client.setSuspended(true)
        old.opened(); old.emit(.data(Data([5, 0, 0, 80, 0, 24])))
        harness.client.nudge(); harness.client.start()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(old.invalidated)
        XCTAssertEqual(harness.transports.count, 1)
        XCTAssertEqual(harness.statuses.last, .suspended)
        harness.client.setSuspended(false)
        harness.client.setSuspended(false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.transports.count, 2)
        harness.client.stop()
    }

    func testHiddenTerminalPolicyPausesWithoutDestroyingItsViewAndRevealingResumes() async throws {
        let harness = BrokerClientHarness()
        let connection = PaneConn(url: harness.url, traceRef: "policy", client: harness.client)
        let view = connection.view
        defer { connection.disconnect() }
        try await Task.sleep(for: .milliseconds(20))
        connection.setVisible(false)
        connection.applyNetworkPolicy(.init(lowData: true), appActive: true)
        XCTAssertTrue(harness.transports[0].invalidated)
        connection.setVisible(true)
        connection.applyNetworkPolicy(.init(lowData: true), appActive: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(harness.transports.count, 2)
        XCTAssertTrue(connection.view === view)
        connection.applyNetworkPolicy(.init(lowData: true), appActive: false)
        XCTAssertTrue(harness.transports[1].invalidated)
        connection.applyNetworkPolicy(.init(lowData: true), appActive: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(harness.transports.count, 3)
    }
}

@MainActor
final class BrokerDialSchedulerTests: XCTestCase {
    func testSingleSlotStillAllowsBackgroundWorkAndCanYieldToForeground() async throws {
        let scheduler = BrokerDialScheduler(capacity: 1)
        let background = UUID(), foreground = UUID()
        var grants: [String] = [], revoked = false
        scheduler.request(id: background, host: "host", foreground: false,
                          grant: { grants.append("background") }, revoke: { revoked = true })
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(grants, ["background"])
        scheduler.request(id: foreground, host: "host", foreground: true,
                          grant: { grants.append("foreground") }, revoke: {})
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(revoked)
        XCTAssertEqual(grants, ["background", "foreground"])
        scheduler.release(foreground)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(grants, ["background", "foreground", "background"])
        scheduler.release(background)
    }

    func testBackgroundAttemptsReserveCapacityForForegroundAndQueueFairly() async throws {
        let scheduler = BrokerDialScheduler(), ids = (0..<4).map { _ in UUID() }
        var grants: [Int] = []
        for i in 0..<3 { scheduler.request(id: ids[i], host: "host", foreground: false, grant: { grants.append(i) }, revoke: {}) }
        scheduler.request(id: ids[3], host: "host", foreground: true, grant: { grants.append(3) }, revoke: {})
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(grants, [0, 1, 3])
        scheduler.release(ids[0])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(grants, [0, 1, 3, 2])
        ids.forEach(scheduler.release)
    }

    func testNewForegroundAttemptCanPreemptAnAttemptThatBecameHidden() async throws {
        let scheduler = BrokerDialScheduler(), ids = (0..<4).map { _ in UUID() }
        var active = Set<Int>(), revoked: [Int] = []
        for i in 0..<3 {
            scheduler.request(id: ids[i], host: "host", foreground: true, grant: { active.insert(i) }, revoke: { active.remove(i); revoked.append(i) })
        }
        try await Task.sleep(for: .milliseconds(20))
        scheduler.prioritize(ids[0], foreground: false)
        scheduler.request(id: ids[3], host: "host", foreground: true, grant: { active.insert(3) }, revoke: {})
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(revoked, [0])
        XCTAssertEqual(active, [1, 2, 3])
        ids.forEach(scheduler.release)
    }

    func testCancelledWaiterNeverDialsAndHostsAreIndependent() async throws {
        let scheduler = BrokerDialScheduler(), ids = (0..<3).map { _ in UUID() }
        var grants: [Int] = []
        for i in 0..<3 { scheduler.request(id: ids[i], host: "one", foreground: false, grant: { grants.append(i) }, revoke: {}) }
        scheduler.release(ids[2])
        let other = UUID()
        scheduler.request(id: other, host: "two", foreground: true, grant: { grants.append(9) }, revoke: {})
        try await Task.sleep(for: .milliseconds(20))
        ids.forEach(scheduler.release)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(grants, [0, 1, 9])
        scheduler.release(other)
    }
}

@MainActor
final class BrokerClientHarness {
    let url: URL
    var transports: [FixtureBrokerTransport] = []
    var statuses: [ConnState] = []
    var onCreate: (FixtureBrokerTransport) -> Void = { _ in }
    private let recovery: BrokerRecoveryConfiguration
    lazy var client: BrokerClient = {
        let client = BrokerClient(url: url, traceRef: "test", scheduler: BrokerDialScheduler(), recovery: recovery, observeNetwork: false) { [weak self] _, opened in
            let transport = FixtureBrokerTransport(opened: opened)
            self?.onCreate(transport); self?.transports.append(transport)
            return transport
        }
        client.onStatus = { [weak self] in self?.statuses.append($0) }
        return client
    }()
    init(url: URL = URL(string: "ws://127.0.0.1:1/ws")!, recovery: BrokerRecoveryConfiguration = .init()) {
        self.url = url; self.recovery = recovery
    }
}

final class FixtureBrokerTransport: BrokerTransportServing {
    let opened: () -> Void
    var openDelay: TimeInterval?
    var firstFrame = false, answersPings = false, invalidated = false
    var pings = 0
    private var receiver: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    init(opened: @escaping () -> Void) { self.opened = opened }
    func resume() {
        guard let openDelay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) { [self] in
            guard !invalidated else { return }
            opened()
            if firstFrame { emit(.data(Data([5, 0, 0, 80, 0, 24]))) }
        }
    }
    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) { receiver = completion }
    func emit(_ message: URLSessionWebSocketTask.Message) { let receive = receiver; receiver = nil; receive?(.success(message)) }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) { completion(nil) }
    func ping(_ completion: @escaping (Error?) -> Void) { pings += 1; if answersPings { completion(nil) } }
    func invalidate() { invalidated = true }
}
