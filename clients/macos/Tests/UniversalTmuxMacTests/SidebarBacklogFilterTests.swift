import XCTest
import SwiftUI
import ArgusProtocol
@testable import UniversalTmuxMac

@MainActor
final class SidebarBacklogFilterTests: XCTestCase {
    private func fixture(defaults: UserDefaults? = nil) -> AppState {
        let monitor = BrokerSessionMonitor(fetch: { _, _ in .failure(.invalidSnapshot) }, probe: { _ in false })
        let state = AppState(isolatedForTesting: true, sessionMonitor: monitor, sidebarPreferences: defaults)
        state.showAgentSessions = false
        state.hiddenSessions = []
        state.backlog = ["local/later", "remote/review"]
        state.machines.append(Machine(id: "remote", name: "remote host", isLocal: false,
                                      httpBase: "http://127.0.0.1:1", wsBase: "ws://127.0.0.1:1"))
        state.sessionsByMachine = [
            "local": [SessionInfo(name: "review", path: "/projects/app", state: "waiting"),
                      SessionInfo(name: "build", path: "/projects/app", state: "working"),
                      SessionInfo(name: "notes", path: "/projects/notes"),
                      SessionInfo(name: "later", path: "/projects/backlog", state: "waiting")],
            "remote": [SessionInfo(name: "review", path: "/work/app", state: "working"),
                       SessionInfo(name: "deploy", path: "/work/app")]
        ]
        return state
    }

    private func names(_ state: AppState, machine: String = "local", query: String = "") -> Set<String> {
        Set(state.folderGroups(for: machine, matching: query).flatMap(\.sessions).map(\.name))
    }

    func testDefaultShowsAllAndFilteringDoesNotChangeSessionsOrSelection() {
        let state = fixture()
        state.navigationOrigin = .agent("sidebar-test")
        state.selection = SessionRef(machineID: "local", session: "later")
        let sessions = state.sessionsByMachine, selection = state.selection, backlog = state.backlog
        XCTAssertFalse(state.hideBackloggedPanels)
        XCTAssertEqual(names(state), ["review", "build", "notes", "later"])
        state.hideBackloggedPanels = true
        XCTAssertEqual(names(state), ["review", "build", "notes"])
        XCTAssertEqual(state.sessionsByMachine, sessions)
        XCTAssertEqual(state.selection, selection)
        XCTAssertEqual(state.backlog, backlog)
        XCTAssertTrue(state.allSessions.contains(SessionRef(machineID: "local", session: "later")),
                      "The palette must retain access to backlog panels")
        state.hideBackloggedPanels = false
        XCTAssertEqual(names(state), ["review", "build", "notes", "later"])
    }

    func testMachineQualifiedBacklogAndStatusesAreIndependent() {
        let state = fixture()
        state.hideBackloggedPanels = true
        XCTAssertEqual(names(state), ["review", "build", "notes"], "Waiting, working, and idle all remain")
        XCTAssertEqual(names(state, machine: "remote"), ["deploy"], "The same name on another machine has its own backlog flag")
        state.backlog.insert("local/build")
        XCTAssertEqual(names(state), ["review", "notes"])
        state.backlog.remove("remote/review")
        XCTAssertEqual(names(state, machine: "remote"), ["review", "deploy"])
    }

    func testSharedWorkspaceBacklogChangesImmediatelyUpdateSidebar() throws {
        let state = fixture()
        state.machines[0].brokerID = "fixture-broker"
        state.sessionsByMachine["local"]?[0].lineageID = "review-lifetime"
        let replica = state.sharedWorkspace.replica
        try replica.bind("sidebar-workspace")
        try replica.acceptSnapshot(.object(["workspaceID": .string("sidebar-workspace"),
                                           "cursor": .number(0), "records": .array([])]))
        state.hideBackloggedPanels = true
        let ref = SessionRef(machineID: "local", session: "review")
        state.setBacklog(ref, included: true)
        XCTAssertTrue(state.backlog.contains(ref.id))
        XCTAssertFalse(names(state).contains("review"))
        state.setBacklog(ref, included: false)
        XCTAssertFalse(state.backlog.contains(ref.id))
        XCTAssertTrue(names(state).contains("review"))
    }

    func testSearchAndFolderGroupsHonorFilterWithoutEmptyGroups() {
        let state = fixture()
        state.hideBackloggedPanels = true
        XCTAssertEqual(names(state, query: " APP "), ["review", "build"])
        XCTAssertEqual(names(state, query: "rev"), ["review"])
        XCTAssertTrue(names(state, query: "later").isEmpty)
        XCTAssertEqual(state.folderGroups(for: "local").map(\.folder), ["/projects/app", "/projects/notes"])
        state.backlog.formUnion(["local/review", "local/build", "local/notes"])
        XCTAssertTrue(state.folderGroups(for: "local").isEmpty)
    }

    func testAgentAndExplicitHideRulesRemainIndependent() {
        let state = fixture()
        state.sessionsByMachine["local"]?.append(SessionInfo(name: "helper", agent: true))
        state.hiddenSessions.insert("local/notes")
        for filtered in [false, true] {
            state.hideBackloggedPanels = filtered
            XCTAssertFalse(names(state).contains("helper"))
            XCTAssertFalse(names(state).contains("notes"))
        }
        state.showAgentSessions = true
        XCTAssertTrue(names(state).contains("helper"))
        state.backlog.insert("local/helper")
        XCTAssertFalse(names(state).contains("helper"))
    }

    func testAttentionRowsRespectFilterWithoutChangingGlobalNotifications() {
        let state = fixture()
        let waiting = state.waitingSessions
        XCTAssertEqual(Set(waiting.map(\.ref.session)), ["review", "later"])
        state.hideBackloggedPanels = true
        XCTAssertEqual(state.sidebarWaitingSessions.map(\.ref.session), ["review"])
        XCTAssertEqual(state.waitingSessions, waiting)
        state.hideBackloggedPanels = false
        XCTAssertEqual(state.sidebarWaitingSessions, waiting)
    }

    func testClosingPanelChoosesOnlyASidebarVisibleNeighbor() {
        let state = fixture()
        state.hideBackloggedPanels = true
        state.hiddenSessions = ["local/build", "local/notes"]
        let review = SessionRef(machineID: "local", session: "review")
        XCTAssertEqual(state.neighborSession(excluding: review), SessionRef(machineID: "remote", session: "deploy"))
        state.backlog.insert("remote/deploy")
        XCTAssertNil(state.neighborSession(excluding: review))
    }

    func testPreferenceSurvivesRelaunchInIsolatedDefaults() throws {
        let suite = "argus-sidebar-filter-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = fixture(defaults: defaults)
        XCTAssertFalse(first.hideBackloggedPanels)
        first.hideBackloggedPanels = true
        XCTAssertTrue(defaults.bool(forKey: AppState.hideBackloggedPanelsKey))
        let reopened = fixture(defaults: defaults)
        XCTAssertTrue(reopened.hideBackloggedPanels)
        XCTAssertEqual(names(reopened), ["review", "build", "notes"])
        reopened.hideBackloggedPanels = false
        XCTAssertFalse(fixture(defaults: defaults).hideBackloggedPanels)
    }

    func testActualToggleFiltersRenderedRowsAndRestoresThemWithoutOpeningAWindow() throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let state = fixture()
        let host = NSHostingView(rootView: SidebarFilterSettingsFixture(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 360 + WorkspaceSidebarSizing.defaultWidth, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        settle()
        for enabled in [true, false] {
            let toggle = try XCTUnwrap(find(host, identifier: "sidebar-hide-backlog"))
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(toggle.responds(to: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            _ = unsafeBitCast(toggle.method(for: selector), to: Press.self)(toggle, selector)
            settle()
            XCTAssertEqual(state.hideBackloggedPanels, enabled)
            XCTAssertEqual(find(host, identifier: "panel-local/later") == nil, enabled)
            XCTAssertNotNil(find(host, identifier: "panel-local/review"))
            XCTAssertEqual(find(host, identifier: "panel-remote/review") == nil, enabled)
            if let prefix = ProcessInfo.processInfo.environment["UT_SIDEBAR_FILTER_SCREENSHOT"] {
                for width in [WorkspaceSidebarSizing.minimumWidth, WorkspaceSidebarSizing.defaultWidth] {
                    host.setFrameSize(NSSize(width: 360 + width, height: 600))
                    settle()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: "\(prefix)-\(enabled ? "on" : "off")-\(Int(width)).png"))
                }
            }
        }
    }

    private func find(_ element: Any, identifier: String, depth: Int = 0) -> NSObject? {
        guard depth < 40, let node = element as? NSObject else { return nil }
        let ids = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
        let found = node.responds(to: ids) ? node.perform(ids)?.takeUnretainedValue() as? String : nil
        if found == identifier { return node }
        let values = node.responds(to: children) ? node.perform(children)?.takeUnretainedValue() as? [Any] : nil
        return (values ?? []).compactMap { find($0, identifier: identifier, depth: depth + 1) }.first
    }
}

/// Uses the shipping control, visibility model, attention section, and session rows.
private struct SidebarFilterSettingsFixture: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Sessions") {
                    SidebarBacklogToggle(isOn: $state.hideBackloggedPanels, label: "Hide backlogged panels in sidebar")
                }
            }
            .formStyle(.grouped)
            .frame(width: 360)
            sidebar
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Argus").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
            NeedsAttentionSection(waiting: state.sidebarWaitingSessions, selection: $state.selection)
            ForEach(state.machines) { machine in
                Text(machine.name.uppercased()).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).padding(.horizontal, 6)
                ForEach(state.folderGroups(for: machine.id)) { group in
                    ForEach(group.sessions) { session in
                        SessionRow(session: session, folderText: group.folder, selected: false, onTap: {})
                            .accessibilityIdentifier("panel-\(machine.id)/\(session.name)")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebarBackground)
    }
}
