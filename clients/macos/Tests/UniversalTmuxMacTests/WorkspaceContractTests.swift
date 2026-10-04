import XCTest
import AppKit
import SwiftUI
import WebKit
import ArgusProtocol
@testable import UniversalTmuxMac

final class WorkspaceContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> ArgusJSON {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../testdata/workspace/" + name).standardizedFileURL
        return try JSONDecoder().decode(ArgusJSON.self, from: Data(contentsOf: url))
    }
    func testSamePortableLocatorFixturesAsKotlin() throws {
        let value = try fixture("locators-v1.json")
        for row in value["websites"].array ?? [] {
            XCTAssertEqual((try? WorkspaceLocator.website(row["url"].string!)) != nil, row["valid"].bool, row["url"].string!)
        }
        for row in value["services"].array ?? [] {
            XCTAssertEqual((try? WorkspaceLocator.service(brokerID: row["brokerID"].string!, port: Int(row["port"].uint64!), path: row["path"].string!)) != nil, row["valid"].bool)
        }
    }
    @MainActor func testSharedWireFixturePreservesUnknownFieldsAndLifetimes() throws {
        let replica = SharedWorkspaceReplica(directory: nil, transport: { _, _, _ in .null })
        try replica.bind("fixture-workspace"); try replica.acceptSnapshot(fixture("replica-v1.json"))
        XCTAssertEqual(replica.data("session-read", "fixture-broker/lifetime-1")?["seenRevision"].uint64, 12)
        XCTAssertNil(replica.data("session-read", "fixture-broker/lifetime-2"))
        let dashboard = try XCTUnwrap(replica.collection("dashboards").first)
        var next = dashboard.data!.object!; next["name"] = .string("Renamed on Mac")
        try replica.enqueue("dashboards", id: dashboard.id, data: .object(next))
        XCTAssertEqual(replica.data("dashboards", dashboard.id)?["futureField"]["keep"].bool, true)
    }
    func testConcurrentJournalAppendAndReplayPreserveWholeUniqueLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("2026-10-04.jsonl")
        let failure = NSLock(); var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            do {
                let text = "{\"id\":\"\(index % 10)\",\"kind\":\"utterance\",\"ts\":\"2026-10-04T12:00:00Z\"}\n"
                try JournalFileStore.append([Data(text.utf8)], to: file, deduplicateIDs: true)
            } catch { failure.lock(); errors.append(error); failure.unlock() }
        }
        XCTAssertTrue(errors.isEmpty)
        let lines = try Data(contentsOf: file).split(separator: 0x0a)
        XCTAssertEqual(lines.count, 10)
        for line in lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
    }

    func testJournalAppendIsolatesInterruptedTailWithoutLosingNextEvent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("day.jsonl")
        try Data("{\"id\":\"interrupted".utf8).write(to: file)
        let complete = Data("{\"id\":\"next\",\"kind\":\"utterance\"}\n".utf8)
        try JournalFileStore.append([complete, complete], to: file, deduplicateIDs: true)
        let lines = try Data(contentsOf: file).split(separator: 0x0a)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(Data(lines[1]) + Data([0x0a]), complete)
    }

    func testAndroidAuthoredSourceArchiveDecodesNatively() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../testdata/workspace/render-source-v1.json").standardizedFileURL
        let archive = try JSONDecoder().decode(RenderSourceArchive.self, from: Data(contentsOf: url))
        XCTAssertEqual(archive.schemaVersion, 1)
        XCTAssertTrue(archive.document.source.contains("## Result 45"))
        XCTAssertEqual(archive.document.sourceOrigin, "fixture-transcript")
        XCTAssertEqual(archive.document.terminal.lines.first?.runs.first?.text, "Terminal fallback")
        if let actual = ProcessInfo.processInfo.environment["UT_ANDROID_SOURCE_ARCHIVE"] {
            let exported = try JSONDecoder().decode(RenderSourceArchive.self, from: Data(contentsOf: URL(fileURLWithPath: actual)))
            XCTAssertTrue(exported.document.source.contains("## Result 45"))
        }
    }

    @MainActor func testSharedLedgerLoadsPublishedBlobAndRendersEvents() async throws {
        let app = AppState(isolatedForTesting: true), coordinator = app.sharedWorkspace
        try coordinator.replica.bind("fixture-workspace")
        try coordinator.replica.acceptSnapshot(fixture("replica-v1.json"))
        try coordinator.replica.enqueue("journal", id: "fixture-broker/2026-10-04", data: .object([
            "kind": .string("day"), "day": .string("2026-10-04"), "hash": .string(String(repeating: "a", count: 64)), "count": .number(2)
        ]))
        let jsonl = """
        {"id":"message-1","kind":"utterance","ts":"2026-10-04T12:00:00Z","machine":"Workspace host","session":"analysis","said":"Compare the two training runs.","saw":"The evaluation table is ready.","src":"phone"}
        {"id":"status-1","kind":"status","ts":"2026-10-04T12:01:00Z","machine":"Workspace host","session":"analysis","to":"milestone","summary":"Evaluation report published."}
        """
        var requested = false
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/ledger").standardizedFileURL
        let panel = LedgerPanel(resourceDirectory: resources, downloadBlob: { hash, _ in
            XCTAssertEqual(hash, String(repeating: "a", count: 64)); requested = true
            return Data(jsonl.utf8)
        })
        panel.workspace = coordinator
        panel.webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: panel.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel.webView
        defer { window.contentView = nil }
        var text = ""
        for _ in 0..<100 {
            text = (try? await panel.webView.evaluateJavaScript("document.body.innerText") as? String) ?? ""
            if text.contains("Compare the two training runs.") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(requested)
        XCTAssertTrue(text.contains("Compare the two training runs."), text)
        _ = try await panel.webView.evaluateJavaScript("document.querySelector('.evrow').click(); document.getAnimations().forEach(animation => animation.finish())")
        try await Task.sleep(nanoseconds: 80_000_000)
        if ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" {
            let image = try await panel.webView.takeSnapshot(configuration: nil)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-ledger-native.png"))
        }
    }

    @MainActor func testNativeFileConflictReviewPreservesDraftWhenRebased() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let tab = FileTab(machine: Machine(id: "fixture", name: "Workspace host", isLocal: false, httpBase: "http://fixture.invalid", wsBase: "ws://fixture.invalid"))
        let doc = OpenDoc(path: "/project/analysis.md", name: "analysis.md", content: .empty)
        doc.draft = "My unsaved analysis"; doc.dirty = true
        doc.originalText = "Original analysis"; doc.revision = "original"
        doc.conflictText = "# Updated analysis\n\nThe remote file changed while this draft was open.\n\nThe local draft remains intact."
        doc.conflictRevision = "remote-revision"
        let host = NSHostingView(rootView: FileConflictReview(text: doc.conflictText!, cancel: {}, keepDraft: { tab.rebaseDraft(doc) }).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 440)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-file-conflict-native.png"))
        }
        func press(_ value: Any, depth: Int = 0) -> Bool {
            guard depth < 40, let node = value as? NSObject else { return false }
            let idSelector = NSSelectorFromString("accessibilityIdentifier")
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            let id = node.responds(to: idSelector) ? node.perform(idSelector)?.takeUnretainedValue() as? String : nil
            if id == "file-conflict-keep-draft" {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                if node.responds(to: selector) {
                    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                    return unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
                }
                node.accessibilityPerformAction(.press)
                return true
            }
            let children = node.responds(to: childrenSelector) ? node.perform(childrenSelector)?.takeUnretainedValue() as? [Any] : nil
            return (children ?? []).contains { press($0, depth: depth + 1) }
        }
        XCTAssertTrue(press(host))
        XCTAssertEqual(doc.draft, "My unsaved analysis")
        XCTAssertEqual(doc.revision, "remote-revision")
        XCTAssertNil(doc.conflictText)
        XCTAssertTrue(doc.dirty)
    }

    @MainActor func testNativeWorkspaceControlsAndSharedCatalogRender() async throws {
        let suite = "workspace.catalog.test.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(isolatedForTesting: true)
        app.machines = [Machine(id: "fixture", name: "Workspace host", isLocal: false, httpBase: "http://fixture.invalid", wsBase: "ws://fixture.invalid", brokerID: "fixture-broker", workspaceID: "fixture-workspace", workspaceEnabled: true)]
        let coordinator = app.sharedWorkspace
        try coordinator.replica.bind("fixture-workspace"); try coordinator.replica.acceptSnapshot(fixture("replica-v1.json"))
        let dashboards = DashboardsModel(restoreSavedTabs: false, startPolling: false, persistTabState: false, tabDefaults: defaults)
        let notebooks = NotebooksModel(defaults: defaults)
        let catalog = SharedCatalogs(app: app, coordinator: coordinator, dashboards: dashboards, notebooks: notebooks, defaults: defaults)
        catalog.reconcile()
        XCTAssertEqual(catalog.dashboardsList.count, 1); XCTAssertEqual(notebooks.notebooks.count, 1)
        catalog.rename(catalog.dashboardsList[0], to: "Reviewed project overview")
        XCTAssertEqual(coordinator.replica.data("dashboards", catalog.dashboardsList[0].id)?["name"].string, "Reviewed project overview")
        catalog.reconcile()
        let root = HStack(alignment: .top, spacing: 24) {
            SharedWorkspaceSettingsView(app: app).frame(width: 330)
            SharedDashboardCatalogView(catalog: catalog)
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root); host.frame = NSRect(x: 0, y: 0, width: 870, height: 440)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-workspace-native.png"))
        }
    }

    @MainActor func testSharedWrappedRendererConsumesPublishedFixture() async throws {
        let app = AppState(isolatedForTesting: true), coordinator = app.sharedWorkspace
        try coordinator.replica.bind("fixture-workspace")
        var snapshot = try fixture("replica-v1.json")
        var records = snapshot["records"].array!
        let index = records.firstIndex { $0["id"].string == "wrapped" }!
        var row = records[index].object!, data = row["data"]!.object!, periods = data["periods"]!.object!, stats = periods["0"]!.object!, totals = stats["totals"]!.object!
        totals["events"] = .number(320); stats["totals"] = .object(totals); periods["0"] = .object(stats); data["periods"] = .object(periods); row["data"] = .object(data); records[index] = .object(row)
        var object = snapshot.object!; object["records"] = .array(records); snapshot = .object(object)
        try coordinator.replica.acceptSnapshot(snapshot)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/wrapped").standardizedFileURL
        let panel = WrappedPanel(resourceDirectory: resources); panel.workspace = coordinator
        panel.webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: panel.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel.webView
        for _ in 0..<100 {
            if let text = try? await panel.webView.evaluateJavaScript("document.body.innerText") as? String, text.contains("Argus\nWrapped") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        panel.refresh()
        try await Task.sleep(nanoseconds: 200_000_000)
        let text = try await panel.webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertTrue(text.contains("4 active days"), text)
        _ = try await panel.webView.evaluateJavaScript("document.getElementById('next').click()")
        try await Task.sleep(nanoseconds: 450_000_000)
        // An unshown WKWebView can throttle its animation timeline. Finish the
        // real transition before inspecting its final visual state.
        _ = try await panel.webView.evaluateJavaScript("document.getAnimations().forEach(animation => animation.finish())")
        if ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" {
            let image = try await panel.webView.takeSnapshot(configuration: nil)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-wrapped-native.png"))
        }
        window.contentView = nil
    }
}
