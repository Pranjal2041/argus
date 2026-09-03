import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

final class WorkspaceRecoveryTests: XCTestCase {
    @MainActor
    func testRecoverySourcesAggregateEveryStoreAndPreferTheOwningOrigin() throws {
        let relay = WorkspaceRecoveryTarget(id: "relay", name: "relay", host: "relay", route: "relay")
        let owner = WorkspaceRecoveryTarget(id: "owner", name: "source-a", host: "source-a", route: "owner")
        let independent = WorkspaceRecoveryTarget(
            id: "independent", name: "source-b", host: "source-b", route: "independent"
        )
        func status(_ json: String) throws -> WorkspaceRecoveryStatus {
            try JSONDecoder().decode(WorkspaceRecoveryStatus.self, from: Data(json.utf8))
        }
        let sharedThroughRelay = try status(#"""
        {"available":true,"snapshot":{"id":"shared","host":"source-a","socket":"ut","capturedAt":"2026-09-02T17:00:00Z"},"targetHost":"relay","candidates":[{"id":"shared","host":"source-a","capturedAt":"2026-09-02T17:00:00Z","panelCount":6,"readyCount":6}],"readyCount":6,"panels":[]}
        """#)
        let sharedThroughOwner = try status(#"""
        {"available":true,"snapshot":{"id":"shared","host":"source-a","socket":"ut","capturedAt":"2026-09-02T17:00:00Z"},"targetHost":"source-a","candidates":[{"id":"shared","host":"source-a","capturedAt":"2026-09-02T17:00:00Z","panelCount":6,"readyCount":6}],"readyCount":6,"panels":[]}
        """#)
        // This independent store exercises the snapshot fallback path rather
        // than the shared-store candidates path above.
        let standalone = try status(#"""
        {"available":true,"snapshot":{"id":"standalone","host":"source-b","socket":"ut","capturedAt":"2026-09-02T18:00:00Z"},"targetHost":"source-b","readyCount":2,"panels":[{"name":"one","directory":"/tmp","agent":"shell","state":"ready","selected":true},{"name":"two","directory":"/tmp","agent":"shell","state":"ready","selected":true}]}
        """#)

        let sources = WorkspaceRecoveryController.recoverySources(
            statusByTarget: [
                relay.id: sharedThroughRelay,
                owner.id: sharedThroughOwner,
                independent.id: standalone,
            ],
            targets: [relay, owner, independent]
        )

        XCTAssertEqual(sources.map(\.id), ["standalone", "shared"])
        XCTAssertEqual(sources.first(where: { $0.id == "shared" })?.originTargetID, owner.id)
        XCTAssertEqual(sources.first(where: { $0.id == "standalone" })?.candidate.panelCount, 2)
    }

    @MainActor
    func testLiveWindowsWorkspaceAppearsAsSourceWithoutBeingALocalFailure() throws {
        let windows = WorkspaceRecoveryTarget(
            id: "windows", name: "pranjala-win", host: "DESKTOP-EFJI6J4", route: "windows"
        )
        let status = try JSONDecoder().decode(
            WorkspaceRecoveryStatus.self,
            from: Data(#"{"available":false,"snapshot":null,"currentServerId":"conpty-current","targetHost":"DESKTOP-EFJI6J4","candidates":[{"id":"windows-live","host":"DESKTOP-EFJI6J4","capturedAt":"2026-09-02T20:00:00Z","panelCount":2,"readyCount":0}],"readyCount":0,"panels":[]}"#.utf8)
        )

        let sources = WorkspaceRecoveryController.recoverySources(
            statusByTarget: [windows.id: status], targets: [windows]
        )

        XCTAssertEqual(sources.map(\.id), ["windows-live"])
        XCTAssertEqual(sources.first?.originTargetID, windows.id)
        XCTAssertEqual(sources.first?.candidate.panelCount, 2)
    }

    @MainActor
    func testRecoveryTargetsIncludeEveryRemoteAndReplaceStaleRouteByLogicalHost() {
        let old = Machine(
            id: "ut-babel-p9-28.tailnet.ts.net",
            name: "babel-p9-28",
            host: "babel-p9-28",
            isLocal: false,
            httpBase: "https://100.66.142.55:8722",
            wsBase: "wss://100.66.142.55:8722"
        )
        let other = Machine(
            id: "ut-babel-u5-24.tailnet.ts.net",
            name: "babel-u5-24",
            host: "babel-u5-24",
            isLocal: false,
            httpBase: "https://100.67.236.60:8722",
            wsBase: "wss://100.67.236.60:8722"
        )
        let replacement = Machine(
            id: "ut-babel-p9-28-1.tailnet.ts.net",
            name: "babel-p9-28",
            host: "babel-p9-28",
            isLocal: false,
            httpBase: "https://100.83.220.68:8722",
            wsBase: "wss://100.83.220.68:8722"
        )
        let orchard = Machine(
            id: "ut-orchard-login-001.tailnet.ts.net",
            name: "orchard-login-001",
            host: "orchard-login-001",
            os: "linux",
            isLocal: false,
            httpBase: "https://100.70.0.10:8722",
            wsBase: "wss://100.70.0.10:8722"
        )
        let windows = Machine(
            id: "ut-pranjala-win.tailnet.ts.net",
            name: "pranjala-win",
            host: "pranjala-win",
            os: "windows",
            isLocal: false,
            httpBase: "https://100.70.0.11:8722",
            wsBase: "wss://100.70.0.11:8722"
        )

        let targets = WorkspaceRecoveryController.recoveryTargets(
            from: [old, other, orchard, windows, replacement]
        )

        XCTAssertEqual(targets.map(\.name), [
            "this mac", "babel-p9-28", "babel-u5-24", "orchard-login-001", "pranjala-win",
        ])
        XCTAssertEqual(targets.first(where: { $0.name == "babel-p9-28" })?.route, replacement.id)
    }

    func testStatusDecodesSafetyModesAndReadyPanels() throws {
        let json = #"""
        {
          "available": true,
          "snapshot": {
            "id": "snapshot-one",
            "host": "mac",
            "socket": "ut",
            "capturedAt": "2026-08-04T20:00:00.000Z"
          },
          "currentServerId": "new-server",
          "targetHost": "babel-q9-16",
          "candidates": [
            {"id":"snapshot-one","host":"babel-p9-28","capturedAt":"2026-08-04T20:00:00.000Z","panelCount":2,"readyCount":2}
          ],
          "readyCount": 2,
          "panels": [
            {
              "name": "research",
              "directory": "/tmp/research",
              "agent": "codex",
              "sessionId": "019f9bfd-86da-7133-8213-39aa87079768",
              "argv": ["codex", "--yolo"],
              "state": "ready",
              "detail": "Resume the exact saved conversation.",
              "restoreCommand": "codex --yolo resume 019f...",
              "selected": true
            },
            {
              "name": "writing",
              "directory": "/tmp/writing",
              "agent": "claude",
              "sessionId": "f1c4d620-2d34-497b-8828-fd4dc9188e67",
              "argv": ["claude", "--dangerously-skip-permissions"],
              "state": "ready",
              "detail": "Resume the exact saved conversation.",
              "restoreCommand": "claude --dangerously-skip-permissions --resume f1c4...",
              "selected": true
            }
          ],
          "error": null
        }
        """#.data(using: .utf8)!

        let status = try JSONDecoder().decode(WorkspaceRecoveryStatus.self, from: json)
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.readyCount, 2)
        XCTAssertEqual(status.panels[0].permissionLabel, "YOLO")
        XCTAssertEqual(status.panels[1].permissionLabel, "BYPASS")
        XCTAssertTrue(status.panels.allSatisfy(\.isReady))
        XCTAssertEqual(status.targetHost, "babel-q9-16")
        XCTAssertEqual(status.candidates?.first?.host, "babel-p9-28")
    }

    func testUnsupportedPanelIsExplicitlyReviewable() throws {
        let json = #"""
        {
          "name":"robocasa",
          "directory":"/data/user_data/pranjala/robocasa",
          "agent":"codex",
          "sessionId":"019fb048-79c0-7600-827c-9400d729dbcb",
          "argv":["codex","--future-option"],
          "state":"unsupported",
          "detail":"unknown startup option \"--future-option\" requires manual review",
          "capturedLaunchReviewable":true,
          "selected":false
        }
        """#.data(using: .utf8)!
        let panel = try JSONDecoder().decode(WorkspaceRecoveryPanel.self, from: json)
        XCTAssertTrue(panel.requiresReview)
        XCTAssertTrue(panel.canUseCapturedLaunch)
        XCTAssertFalse(panel.isReady)
        XCTAssertEqual(panel.detail, "unknown startup option \"--future-option\" requires manual review")
    }

    @MainActor
    func testRemoteRecoveryUsesBrokerProtocolWithoutPlatformShellSyntax() {
        let arguments = WorkspaceRecoveryController.remoteRecoveryArguments([
            "recovery", "restore", "--snapshot", "snapshot-1",
            "--session", "panel with spaces", "--bootstrap=false",
        ], target: "windows-route")
        XCTAssertEqual(arguments, [
            "recovery", "remote", "--target", "windows-route",
            "restore", "--snapshot", "snapshot-1",
            "--session", "panel with spaces", "--bootstrap=false",
        ])
    }

    @MainActor
    func testControllerNeverSelectsUnavailablePanel() throws {
        let json = #"""
        {
          "available": true,
          "snapshot": {"id":"s","host":"mac","socket":"ut","capturedAt":"2026-08-04T20:00:00Z"},
          "currentServerId": "new",
          "readyCount": 1,
          "panels": [
            {"name":"ready","directory":"/tmp","agent":"shell","state":"ready","selected":true},
            {"name":"conflict","directory":"/tmp","agent":"shell","state":"conflict","detail":"Name conflict","selected":false}
          ],
          "error": null
        }
        """#.data(using: .utf8)!
        let status = try JSONDecoder().decode(WorkspaceRecoveryStatus.self, from: json)
        let controller = WorkspaceRecoveryController()
        controller.status = status
        controller.selectAll()
        XCTAssertEqual(controller.selected, ["ready"])
        controller.toggle("conflict")
        XCTAssertEqual(controller.selected, ["ready"])
        controller.toggle("ready")
        XCTAssertTrue(controller.selected.isEmpty)
    }

    @MainActor
    func testMissingFolderBecomesRestorableOnlyAfterExplicitValidEdit() throws {
        let json = #"""
        {
          "available": false,
          "snapshot": {"id":"s","host":"babel-p9-28","socket":"ut","capturedAt":"2026-09-03T12:00:00Z"},
          "readyCount": 0,
          "panels": [
            {
              "name":"research",
              "directory":"/sandbox/research",
              "suggestedDirectory":"/data/user_data/pranjala/research",
              "agent":"codex",
              "executable":"/home/pranjala/.local/bin/codex",
              "argv":["/home/pranjala/.local/bin/codex","--yolo","resume","019fb048-79c0-7600-827c-9400d729dbcb"],
              "sessionId":"019fb048-79c0-7600-827c-9400d729dbcb",
              "state":"missing-directory",
              "detail":"The original working directory is no longer available.",
              "selected":false
            }
          ]
        }
        """#.data(using: .utf8)!
        let controller = WorkspaceRecoveryController()
        controller.status = try JSONDecoder().decode(WorkspaceRecoveryStatus.self, from: json)
        let panel = try XCTUnwrap(controller.status?.panels.first)

        controller.selectAll()
        XCTAssertTrue(controller.selected.isEmpty)
        var edit = controller.edit(for: panel)
        XCTAssertEqual(edit.directory, "/data/user_data/pranjala/research")
        XCTAssertEqual(edit.agent, "codex")
        XCTAssertEqual(edit.sessionId, "019fb048-79c0-7600-827c-9400d729dbcb")
        XCTAssertEqual(edit.executable, "/home/pranjala/.local/bin/codex")
        XCTAssertNil(edit.validationError)

        edit.arguments = ["--yolo"]
        controller.saveEdit(edit)
        XCTAssertEqual(controller.selected, ["research"])
        XCTAssertTrue(controller.isRestorable(panel))

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String: Any]
        XCTAssertEqual(encoded?["panel"] as? String, "research")
        XCTAssertEqual(encoded?["directory"] as? String, "/data/user_data/pranjala/research")
        XCTAssertEqual(encoded?["arguments"] as? [String], ["--yolo"])
    }

    @MainActor
    func testControllerKeepsUnsupportedMachineVisibleButCannotSelectIt() {
        let controller = WorkspaceRecoveryController()
        controller.targets = [
            WorkspaceRecoveryTarget(id: "local", name: "this mac", host: "this mac", route: nil),
            WorkspaceRecoveryTarget(id: "orchard", name: "orchard-login-001", host: "orchard-login-001", route: "orchard"),
            WorkspaceRecoveryTarget(id: "windows", name: "pranjala-win", host: "pranjala-win", route: "windows"),
        ]
        controller.targetIssues = ["windows": "This broker does not support workspace recovery."]

        controller.selectTarget("orchard")
        XCTAssertEqual(controller.selectedTargetID, "orchard")
        controller.selectTarget("windows")
        XCTAssertEqual(controller.selectedTargetID, "orchard")
        XCTAssertEqual(controller.targets.map(\.name), ["this mac", "orchard-login-001", "pranjala-win"])
    }

    @MainActor
    func testRecoverySheetRendersAtItsSupportedSize() throws {
        let json = #"""
        {
          "available": true,
          "snapshot": {"id":"old-mac","host":"babel-p9-28","socket":"ut","capturedAt":"2026-08-04T20:00:00.000Z"},
          "currentServerId": "new-babel",
          "targetHost": "babel-q9-16",
          "candidates": [
            {"id":"old-mac","host":"babel-p9-28","capturedAt":"2026-08-04T20:00:00.000Z","panelCount":4,"readyCount":4},
            {"id":"older","host":"babel-u5-16","capturedAt":"2026-08-03T20:00:00.000Z","panelCount":2,"readyCount":2}
          ],
          "readyCount": 4,
          "panels": [
            {"name":"cua_speed_run_fable","directory":"/Users/pranjal/Developer/cua-speedrun","agent":"codex","argv":["codex","--yolo"],"state":"ready","detail":"Resume the exact saved conversation.","selected":true},
            {"name":"spatial_sound","directory":"/Users/pranjal/Developer/spatial_sound","agent":"claude","argv":["claude","--dangerously-skip-permissions"],"state":"ready","detail":"Resume the exact saved conversation.","selected":true},
            {"name":"econ_kernel","directory":"/Users/pranjal/Developer/econ_kernel","agent":"codex","argv":["codex","--yolo"],"state":"ready","detail":"Resume the exact saved conversation.","selected":true},
            {"name":"pace_zsh","directory":"/Users/pranjal/Developer/pace","agent":"shell","state":"ready","detail":"Restore an interactive shell in its original folder.","selected":true},
            {"name":"manual_panel","directory":"/tmp/manual","agent":"codex","sessionId":"019fb048-79c0-7600-827c-9400d729dbcb","argv":["codex","--future-option"],"state":"unsupported","detail":"Unknown startup option --future-option.","selected":false},
            {"name":"existing_panel","directory":"/tmp/existing","agent":"codex","state":"already-running","detail":"This exact workspace is already running.","selected":false},
            {"name":"renamed_panel","directory":"/tmp/old","agent":"claude","state":"conflict","detail":"A different live session already uses this panel name.","selected":false}
          ],
          "error": null
        }
        """#.data(using: .utf8)!
        let controller = WorkspaceRecoveryController()
        controller.status = try JSONDecoder().decode(WorkspaceRecoveryStatus.self, from: json)
        controller.targets = [
            WorkspaceRecoveryTarget(id: "local", name: "this mac", host: "this mac", route: nil),
            WorkspaceRecoveryTarget(id: "orchard", name: "orchard-login-001", host: "orchard-login-001", route: "orchard-login-001")
        ]
        controller.selectedTargetID = "orchard"
        controller.selectedSourceID = "old-mac"
        controller.selectAll()
        let host = NSHostingView(rootView: WorkspaceRecoveryView(recovery: controller))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 620)

        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = ProcessInfo.processInfo.environment["UT_RECOVERY_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testRecoveryReviewRendersActionableDetails() throws {
        let json = #"""
        {
          "name":"manual_panel",
          "directory":"/data/user_data/pranjala/research",
          "agent":"codex",
          "sessionId":"019fb048-79c0-7600-827c-9400d729dbcb",
          "argv":["/home/pranjala/bin/codex","--future-option"],
          "state":"unsupported",
          "detail":"Unknown startup option --future-option cannot be replayed safely.",
          "capturedLaunchReviewable":true,
          "selected":false
        }
        """#.data(using: .utf8)!
        let panel = try JSONDecoder().decode(WorkspaceRecoveryPanel.self, from: json)
        var launchCount = 0
        let host = NSHostingView(rootView: WorkspaceRecoveryReviewView(
            panel: panel, scale: 1, launchCapturedAction: { launchCount += 1 }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 590)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 590),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        let launchPoint = NSPoint(x: 430, y: 72)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: launchPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: launchPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0
        ))
        window.sendEvent(down)
        window.sendEvent(up)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(launchCount, 1)
        window.orderOut(nil)
        window.contentView = nil
        if let path = ProcessInfo.processInfo.environment["UT_RECOVERY_REVIEW_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testRecoveryEditorRendersEveryPortableCorrectionField() throws {
        let json = #"""
        {
          "name":"research",
          "directory":"/sandbox/research",
          "suggestedDirectory":"/data/user_data/pranjala/research",
          "agent":"codex",
          "sessionId":"019fb048-79c0-7600-827c-9400d729dbcb",
          "executable":"/home/pranjala/.local/bin/codex",
          "argv":["/home/pranjala/.local/bin/codex","--yolo","resume","019fb048-79c0-7600-827c-9400d729dbcb"],
          "codexHome":"/home/pranjala/.codex2",
          "state":"missing-directory",
          "detail":"The original working directory is no longer available.",
          "selected":false
        }
        """#.data(using: .utf8)!
        let panel = try JSONDecoder().decode(WorkspaceRecoveryPanel.self, from: json)
        let host = NSHostingView(rootView: WorkspaceRecoveryEditView(
            panel: panel,
            edit: WorkspaceRecoveryEdit(panel: panel),
            scale: 1,
            saveAction: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 640)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = ProcessInfo.processInfo.environment["UT_RECOVERY_EDIT_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }

}
