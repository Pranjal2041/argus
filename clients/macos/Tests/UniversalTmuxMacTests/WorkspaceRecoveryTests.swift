import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

final class WorkspaceRecoveryTests: XCTestCase {
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
          "selected":false
        }
        """#.data(using: .utf8)!
        let panel = try JSONDecoder().decode(WorkspaceRecoveryPanel.self, from: json)
        XCTAssertTrue(panel.requiresReview)
        XCTAssertFalse(panel.isReady)
        XCTAssertEqual(panel.detail, "unknown startup option \"--future-option\" requires manual review")
    }

    @MainActor
    func testRemoteRecoveryCommandQuotingPreservesPanelNames() {
        XCTAssertEqual(WorkspaceRecoveryController.shellQuote("plain-panel"), "plain-panel")
        XCTAssertEqual(WorkspaceRecoveryController.shellQuote("panel with spaces"), "'panel with spaces'")
        XCTAssertEqual(WorkspaceRecoveryController.shellQuote("it's-safe"), "'it'\"'\"'s-safe'")
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
            WorkspaceRecoveryTarget(id: "q9", name: "babel-q9-16", host: "babel-q9-16", route: "babel-q9-16")
        ]
        controller.selectedTargetID = "q9"
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
          "selected":false
        }
        """#.data(using: .utf8)!
        let panel = try JSONDecoder().decode(WorkspaceRecoveryPanel.self, from: json)
        let host = NSHostingView(rootView: WorkspaceRecoveryReviewView(panel: panel, scale: 1))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 590)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = ProcessInfo.processInfo.environment["UT_RECOVERY_REVIEW_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }
}
