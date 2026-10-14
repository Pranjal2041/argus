import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class AgentActivityTests: XCTestCase {
    func testBrokerUpdatesDriveRunningUnseenAndViewedIndicators() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        var currentState = "working"
        let names = AgentProvider.allCases.map(\.rawValue)
        let monitor = BrokerSessionMonitor(fetch: { _, _ in
            .success(names.map { SessionInfo(name: $0, state: currentState) })
        }, probe: { _ in false })
        let app = AppState(isolatedForTesting: true, sessionMonitor: monitor)
        app.selection = nil
        app.unseen = []
        let machine = try XCTUnwrap(app.machines.first)
        let host = NSHostingView(rootView: ActivityFixture(app: app, machineID: machine.id))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 220)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }

        func capture(_ label: String) throws {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            if let prefix = ProcessInfo.processInfo.environment["UT_ACTIVITY_SCREENSHOT"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "\(prefix)-\(label).png"))
            }
        }
        for state in ["working", "idle"] {
            currentState = state
            let done = expectation(description: "publish \(state)")
            monitor.refresh(machine, scope: .all, force: true) { done.fulfill() }
            await fulfillment(of: [done], timeout: 3)
            for name in names {
                let ref = SessionRef(machineID: machine.id, session: name)
                let unseen = app.unseen.contains(ref.id)
                XCTAssertEqual(unseen, state == "idle")
                let style = AgentIndicatorStyle.resolve(state: AgentState(raw: state), attached: false, unseen: unseen)
                XCTAssertEqual(style.color, state == "working" ? Theme.running : Theme.unseen)
                XCTAssertEqual(style.pulses, state == "working")
            }
            try capture(state == "working" ? "running" : "unseen")
        }

        // Press the actual rendered controls; human selection must acknowledge
        // each result and turn the very same indicator green.
        for name in names {
            let node = try XCTUnwrap(find(host, identifier: "view-\(name)"))
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(node.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector))
            XCTAssertFalse(app.unseen.contains(SessionRef(machineID: machine.id, session: name).id))
        }
        XCTAssertTrue(app.unseen.isEmpty)
        XCTAssertEqual(AgentIndicatorStyle.resolve(state: .idle, attached: false).color, Theme.attached)
        try capture("viewed")
    }

    private func find(_ element: Any, identifier: String, depth: Int = 0) -> NSObject? {
        guard depth < 40, let node = element as? NSObject else { return nil }
        let id = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
        if node.responds(to: id), node.perform(id)?.takeUnretainedValue() as? String == identifier { return node }
        guard node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [Any] else { return nil }
        return values.compactMap { find($0, identifier: identifier, depth: depth + 1) }.first
    }
}

private struct ActivityFixture: View {
    @ObservedObject var app: AppState
    let machineID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(app.sessionsByMachine[machineID] ?? [], id: \.name) { session in
                let ref = SessionRef(machineID: machineID, session: session.name)
                let style = AgentIndicatorStyle.resolve(state: AgentState(raw: session.state), attached: false,
                                                        unseen: app.unseen.contains(ref.id))
                HStack {
                    AgentIndicator(style: style)
                    Text(session.name.capitalized).frame(width: 70, alignment: .leading)
                    Text(style.help).foregroundStyle(Theme.textSecondary).frame(width: 150, alignment: .leading)
                    Spacer()
                    Button("View") { app.selection = ref }.accessibilityIdentifier("view-\(session.name)")
                }
            }
        }.font(.system(size: 13)).padding(24).frame(width: 460, height: 220).background(Theme.appBackground)
    }
}
