import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

final class ArtifactStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-artifact-tests-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPDFAndManifestRoundTripAsOneDurableArtifact() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let context = panel(name: "vlm_gating", stableID: "$7")
        let created = Calendar.current.date(from: DateComponents(
            year: 2024, month: 7, day: 20, hour: 12, minute: 0, second: 0
        ))!
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let bytes = Data("exact-pdf-bytes".utf8)

        let saved = try await disk.savePDF(
            bytes,
            panel: context,
            presentation: "rendered",
            createdAt: created,
            id: id
        )
        let loaded = try await disk.load()

        XCTAssertEqual(loaded, [saved])
        XCTAssertEqual(saved.filename, "vlm_gating — 2024-07-20 12.00.00.pdf")
        XCTAssertEqual(saved.relativePath, "pdf/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.pdf")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(saved.relativePath)), bytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("records/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json").path
        ))
    }

    func testRenameChangesOnlyDisplayMetadataAndPersists() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let bytes = Data("pdf".utf8)
        let saved = try await disk.savePDF(bytes, panel: panel(), presentation: "terminal")
        let originalURL = root.appendingPathComponent(saved.relativePath)

        let renamed = try await disk.rename(saved, to: "  final/results  ")
        let loaded = try await disk.load()

        XCTAssertEqual(renamed.filename, "final-results.pdf")
        XCTAssertEqual(renamed.relativePath, saved.relativePath)
        XCTAssertEqual(loaded, [renamed])
        XCTAssertEqual(try Data(contentsOf: originalURL), bytes)
        XCTAssertEqual(renamed.titleSource, ArtifactTitleSource.manual)
    }

    @MainActor
    func testAutomaticTitleReplacesFallbackAndPersists() async throws {
        let provider = FixedArtifactTitleProvider("Router Accuracy Comparison")
        let store = ArtifactStore(
            rootURL: root,
            loadImmediately: false,
            logEvents: false,
            titleProvider: provider
        )

        let saved = try await store.savePDF(
            Data("pdf".utf8),
            panel: panel(name: "vlm_gating"),
            presentation: "rendered"
        )
        let updated = await waitForArtifact(in: store, id: saved.id) {
            $0.titleSource == ArtifactTitleSource.codex
        }

        XCTAssertEqual(updated?.filename, "Router Accuracy Comparison.pdf")
        XCTAssertEqual(updated?.titleSource, ArtifactTitleSource.codex)
        let loaded = try await ArtifactDiskStore(rootURL: root).load()
        XCTAssertEqual(loaded.first?.filename, "Router Accuracy Comparison.pdf")
        XCTAssertEqual(loaded.first?.titleSource, ArtifactTitleSource.codex)
    }

    @MainActor
    func testManualRenameAlwaysWinsAgainstLateAutomaticTitle() async throws {
        let provider = DeferredArtifactTitleProvider()
        let store = ArtifactStore(
            rootURL: root,
            loadImmediately: false,
            logEvents: false,
            titleProvider: provider
        )
        let saved = try await store.savePDF(
            Data("pdf".utf8),
            panel: panel(),
            presentation: "rendered"
        )
        for _ in 0..<100 {
            if await provider.didStart() { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let providerStarted = await provider.didStart()
        XCTAssertTrue(providerStarted)

        _ = try await store.rename(saved, to: "My Deliberate Name")
        await provider.finish(with: "Late Model Name")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.records.first?.filename, "My Deliberate Name.pdf")
        XCTAssertEqual(store.records.first?.titleSource, ArtifactTitleSource.manual)
        let loaded = try await ArtifactDiskStore(rootURL: root).load()
        XCTAssertEqual(loaded.first?.filename, "My Deliberate Name.pdf")
        XCTAssertEqual(loaded.first?.titleSource, ArtifactTitleSource.manual)
    }

    func testCodexTitleCommandPinsLunaAndMediumReasoning() {
        let arguments = CodexArtifactTitleProvider.commandArguments(
            outputURL: URL(fileURLWithPath: "/tmp/title.txt"),
            workingDirectory: URL(fileURLWithPath: "/tmp/title-work"),
            imageURL: URL(fileURLWithPath: "/tmp/screenshot.png")
        )

        XCTAssertTrue(arguments.contains("gpt-5.6-luna"))
        XCTAssertTrue(arguments.contains("model_reasoning_effort=\"medium\""))
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("read-only"))
        XCTAssertTrue(arguments.contains("/tmp/screenshot.png"))
    }

    func testAutomaticTitleSanitizingAndVersionNumbersRemainReadable() {
        XCTAssertEqual(
            CodexArtifactTitleProvider.sanitized("**Title: Router Accuracy Comparison.pdf.**"),
            "Router Accuracy Comparison"
        )
        XCTAssertEqual(
            ArtifactFilename.normalized("GPT-5.6 Router Comparison", fileExtension: "pdf"),
            "GPT-5.6 Router Comparison.pdf"
        )
    }

    func testOnlyUntouchedLegacyDefaultsAreEligibleForBackfill() {
        let context = panel(name: "spatial_fable")
        let createdAt = Date(timeIntervalSince1970: 1_721_500_000)
        var legacy = ArtifactRecord(
            filename: ArtifactFilename.generated(
                for: context,
                at: createdAt,
                fileExtension: "pdf"
            ),
            createdAt: createdAt,
            panel: context,
            presentation: "rendered",
            relativePath: "pdf/legacy.pdf",
            byteCount: 1
        )

        XCTAssertTrue(ArtifactAutomaticTitleEligibility.isEligible(legacy))
        legacy.filename = "Hand Picked Result.pdf"
        XCTAssertFalse(ArtifactAutomaticTitleEligibility.isEligible(legacy))
        legacy.titleSource = ArtifactTitleSource.manual
        XCTAssertFalse(ArtifactAutomaticTitleEligibility.isEligible(legacy))
    }

    func testScreenshotPNGAndManifestRoundTripAsPanelArtifact() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let context = panel(name: "spatial_sol", stableID: "$4")
        let created = Calendar.current.date(from: DateComponents(
            year: 2024, month: 7, day: 20, hour: 12, minute: 1, second: 2
        ))!
        let id = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let bytes = Data("png-image-bytes".utf8)

        let saved = try await disk.saveScreenshotPNG(
            bytes,
            panel: context,
            createdAt: created,
            id: id
        )
        let loaded = try await disk.load()

        XCTAssertEqual(loaded, [saved])
        XCTAssertEqual(saved.kind, ArtifactKind.screenshotPNG)
        XCTAssertTrue(saved.isImage)
        XCTAssertEqual(saved.filename, "spatial_sol — 2024-07-20 12.01.02.png")
        XCTAssertEqual(saved.relativePath, "images/bbbbbbbb-cccc-dddd-eeee-ffffffffffff.png")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(saved.relativePath)), bytes)
    }

    func testScreenshotRenamePreservesItsImageExtension() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let saved = try await disk.saveScreenshotPNG(Data("png".utf8), panel: panel())

        let renamed = try await disk.rename(saved, to: "comparison.final.pdf")
        let loaded = try await disk.load()

        XCTAssertEqual(renamed.filename, "comparison.final.png")
        XCTAssertEqual(renamed.relativePath, saved.relativePath)
        XCTAssertEqual(loaded, [renamed])
    }

    func testExplicitFileSnapshotPreservesBytesSourceAndType() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let bytes = Data("{\"verdict\":\"keep\"}".utf8)
        let id = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA")!

        let saved = try await disk.saveFile(
            bytes,
            filename: "analysis.json",
            panel: panel(name: "spatial_sol"),
            sourcePath: "/workspace/results/analysis.json",
            contentType: "application/json",
            presentation: "file-snapshot",
            id: id
        )
        let loaded = try await disk.load()

        XCTAssertEqual(loaded, [saved])
        XCTAssertEqual(saved.kind, ArtifactKind.fileSnapshot)
        XCTAssertEqual(saved.filename, "analysis.json")
        XCTAssertEqual(saved.relativePath, "files/cccccccc-dddd-eeee-ffff-aaaaaaaaaaaa.json")
        XCTAssertEqual(saved.sourcePath, "/workspace/results/analysis.json")
        XCTAssertEqual(saved.contentType, "application/json")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(saved.relativePath)), bytes)
    }

    func testStreamedFileSnapshotCopiesBeforeTemporarySourceDisappears() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let source = root.appendingPathComponent("incoming-model.bin")
        let bytes = Data(repeating: 0xA5, count: 4096)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: source)

        let saved = try await disk.saveFile(
            at: source,
            filename: "model.bin",
            panel: panel(),
            sourcePath: "/remote/model.bin",
            contentType: "application/octet-stream",
            presentation: "file-snapshot"
        )
        try FileManager.default.removeItem(at: source)
        let loaded = try await disk.load()

        XCTAssertEqual(saved.byteCount, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(saved.relativePath)), bytes)
        XCTAssertEqual(loaded, [saved])
    }

    func testFileSnapshotRenameKeepsStoredType() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let saved = try await disk.saveFile(
            Data("notes".utf8),
            filename: "notes.md",
            panel: panel(),
            sourcePath: "/workspace/notes.md",
            contentType: "text/markdown",
            presentation: "file-draft"
        )

        let renamed = try await disk.rename(saved, to: "review.txt")

        XCTAssertEqual(renamed.filename, "review.md")
        XCTAssertEqual(renamed.relativePath, saved.relativePath)
        XCTAssertEqual(renamed.presentation, "file-draft")
    }

    func testMarkdownSnapshotsAreRecognizedByExtensionOrMediaType() {
        let extensionRecord = ArtifactRecord(
            filename: "notes.md",
            panel: panel(),
            presentation: "file-snapshot",
            relativePath: "files/notes.md",
            byteCount: 1,
            contentType: "application/octet-stream"
        )
        let mediaTypeRecord = ArtifactRecord(
            filename: "README",
            panel: panel(),
            presentation: "file-snapshot",
            relativePath: "files/readme",
            byteCount: 1,
            contentType: "text/markdown; charset=utf-8"
        )
        let plainTextRecord = ArtifactRecord(
            filename: "notes.txt",
            panel: panel(),
            presentation: "file-snapshot",
            relativePath: "files/notes.txt",
            byteCount: 1,
            contentType: "text/plain"
        )

        XCTAssertTrue(extensionRecord.isMarkdown)
        XCTAssertTrue(mediaTypeRecord.isMarkdown)
        XCTAssertFalse(plainTextRecord.isMarkdown)
    }

    func testMarkdownReadingCopyUsesAUsefulTitle() {
        XCTAssertEqual(
            MarkdownEPUBExporter.suggestedTitle(for: "Experiment notes.md"),
            "Experiment notes"
        )
        XCTAssertEqual(MarkdownEPUBExporter.suggestedTitle(for: ""), "Argus Markdown")
    }

    func testDeleteRemovesManifestAndPDF() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let saved = try await disk.savePDF(Data("pdf".utf8), panel: panel(), presentation: "rendered")

        try await disk.delete(saved)

        let remaining = try await disk.load()
        XCTAssertEqual(remaining, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(saved.relativePath).path))
    }

    func testSearchUsesFilenameAndSortOrdersAreDeterministic() {
        let earlier = record(filename: "Alpha.pdf", seconds: 100, id: "AAAAAAAA-0000-0000-0000-000000000001")
        let later = record(filename: "Beta.pdf", seconds: 200, id: "AAAAAAAA-0000-0000-0000-000000000002")

        XCTAssertEqual(
            ArtifactLibraryQuery.records([earlier, later], filenameQuery: "alp").map(\.id),
            [earlier.id]
        )
        XCTAssertEqual(
            ArtifactLibraryQuery.records([earlier, later], sort: .newest).map(\.id),
            [later.id, earlier.id]
        )
        XCTAssertEqual(
            ArtifactLibraryQuery.records([earlier, later], sort: .nameDescending).map(\.id),
            [later.id, earlier.id]
        )
        // A panel name is deliberately not part of filename search.
        XCTAssertTrue(ArtifactLibraryQuery.records([earlier], filenameQuery: "vlm_gating").isEmpty)
    }

    func testSessionLineageGroupsArtifactsAcrossRenameAndFolderChange() {
        let before = panel(
            name: "old_name", stableID: "$12", lineageID: "tmux:101:200:$12",
            folder: "/tmp/old"
        )
        let after = panel(
            name: "new_name", stableID: "$12", lineageID: "tmux:101:200:$12",
            folder: "/tmp/new"
        )
        XCTAssertNotEqual(before.key, after.key)

        let records = [
            record(filename: "Before.pdf", seconds: 100, panel: before),
            record(filename: "After.pdf", seconds: 200, panel: after),
        ]
        let groups = ArtifactLibraryQuery.panels(records)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[0].context.sessionName, "new_name")
        XCTAssertEqual(ArtifactLibraryQuery.records(records, panel: before).count, 2)
        XCTAssertEqual(ArtifactLibraryQuery.records(records, panel: after).count, 2)
    }

    func testReusedTmuxTransportHandleNeverMixesUnrelatedPanels() {
        let original = panel(
            name: "open_conjecture", stableID: "$11",
            folder: "/Users/me/open_conjectures"
        )
        let reused = panel(
            name: "osworld_pareto2", stableID: "$11",
            folder: "/Users/me/find_osworld2_pareto"
        )
        let records = [
            record(filename: "Conjecture.pdf", seconds: 100, panel: original),
            record(filename: "Pareto.pdf", seconds: 200, panel: reused),
        ]

        XCTAssertNotEqual(original.key, reused.key)
        XCTAssertEqual(ArtifactLibraryQuery.panels(records).count, 2)
        XCTAssertEqual(ArtifactLibraryQuery.records(records, panel: original).map(\.filename), ["Conjecture.pdf"])
        XCTAssertEqual(ArtifactLibraryQuery.records(records, panel: reused).map(\.filename), ["Pareto.pdf"])
    }

    func testRecreatedPanelRejoinsOlderArtifactsDespiteNewTmuxHandle() {
        let beforeRestart = panel(name: "captcha_related_work", stableID: "$5")
        let afterRestart = panel(name: "captcha_related_work", stableID: "$3")
        let records = [
            record(filename: "Before.pdf", seconds: 100, panel: beforeRestart),
            record(filename: "After.pdf", seconds: 200, panel: afterRestart),
        ]

        let groups = ArtifactLibraryQuery.panels(records)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(ArtifactLibraryQuery.records(records, panel: afterRestart).count, 2)
    }

    func testPanelCanChangeFoldersWithoutLosingOlderArtifacts() {
        let projectA = panel(name: "zsh2", stableID: "$14", folder: "/Users/me/project-a")
        let projectB = panel(name: "zsh2", stableID: "$14", folder: "/Users/me/project-b")
        let records = [
            record(filename: "A.pdf", seconds: 100, panel: projectA),
            record(filename: "B.pdf", seconds: 200, panel: projectB),
        ]

        let groups = ArtifactLibraryQuery.panels(records)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
    }

    func testBabelWorkerMoveAndWindowsPathSpellingPreserveLogicalPanel() {
        let babelOld = panel(
            name: "vlm_gating", stableID: "$0",
            machineID: "ut-babel-n5-24.tail.example", machineName: "babel-n5-24",
            machineHost: "babel-n5-24", folder: "/data/user_data/me/vlm_gating"
        )
        let babelNew = panel(
            name: "vlm_gating", stableID: "$22",
            machineID: "ut-babel-p9-16.tail.example", machineName: "babel-p9-16",
            machineHost: "babel-p9-16", folder: "/data/user_data/me/vlm_gating/"
        )
        let windowsOld = panel(
            name: "gar_codex", stableID: nil,
            machineID: "win.tail.example", machineName: "windows",
            machineHost: "DESKTOP-ONE", folder: #"D:\Gym_Anything"#
        )
        let windowsNew = panel(
            name: "gar_codex", stableID: nil,
            machineID: "win.tail.example", machineName: "windows",
            machineHost: "desktop-one", folder: "d:/gym_anything/"
        )

        XCTAssertEqual(babelOld.key, babelNew.key)
        XCTAssertEqual(windowsOld.key, windowsNew.key)
    }

    func testIdenticalBrokerLineageOnTwoBabelWorkersCannotMixDifferentPanels() {
        let first = panel(
            name: "first_experiment", stableID: "$0", lineageID: "tmux:101:200:$0",
            machineID: "babel-n5-id", machineName: "babel-n5-24",
            machineHost: "babel-n5-24", folder: "/shared/first"
        )
        let second = panel(
            name: "second_experiment", stableID: "$0", lineageID: "tmux:101:200:$0",
            machineID: "babel-p9-id", machineName: "babel-p9-16",
            machineHost: "babel-p9-16", folder: "/shared/second"
        )
        let records = [
            record(filename: "First.pdf", seconds: 100, panel: first),
            record(filename: "Second.pdf", seconds: 200, panel: second),
        ]

        XCTAssertEqual(first.machineScope, second.machineScope)
        XCTAssertNotEqual(first.lineageKey, second.lineageKey)
        XCTAssertEqual(ArtifactLibraryQuery.panels(records).count, 2)
    }

    func testPanelIndexHonorsTheSameTimeAndNameSortControl() {
        let alpha = record(
            filename: "Late.pdf", seconds: 200,
            panel: panel(name: "alpha", stableID: "$1")
        )
        let zeta = record(
            filename: "Early.pdf", seconds: 100,
            panel: panel(name: "zeta", stableID: "$2")
        )

        XCTAssertEqual(
            ArtifactLibraryQuery.panels([alpha, zeta], sort: .newest).map(\.context.sessionName),
            ["alpha", "zeta"]
        )
        XCTAssertEqual(
            ArtifactLibraryQuery.panels([alpha, zeta], sort: .nameDescending).map(\.context.sessionName),
            ["zeta", "alpha"]
        )
    }

    func testLoaderReportsBrokenRecordsWithoutHidingHealthyArtifacts() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let healthy = try await disk.savePDF(Data("pdf".utf8), panel: panel(), presentation: "rendered")
        let recordsDir = root.appendingPathComponent("records", isDirectory: true)
        try Data("not-json".utf8).write(to: recordsDir.appendingPathComponent("broken.json"))

        let missing = ArtifactRecord(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
            filename: "Missing.pdf",
            panel: panel(name: "missing"),
            presentation: "rendered",
            relativePath: "pdf/bbbbbbbb-0000-0000-0000-000000000001.pdf",
            byteCount: 3
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(missing).write(
            to: recordsDir.appendingPathComponent("bbbbbbbb-0000-0000-0000-000000000001.json")
        )

        let report = try await disk.loadReport()

        XCTAssertEqual(report.records, [healthy])
        XCTAssertEqual(report.issues.count, 2)
        XCTAssertTrue(report.issues.contains { $0.manifest == "broken.json" && $0.reason.contains("Invalid manifest") })
        XCTAssertTrue(report.issues.contains { $0.reason.contains("Saved content is missing") })
    }

    func testBrokenDuplicateCannotClaimHealthyArtifactID() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let id = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
        let healthy = try await disk.savePDF(
            Data("pdf".utf8), panel: panel(), presentation: "rendered", id: id
        )
        let brokenCopy = ArtifactRecord(
            id: id,
            filename: "Broken copy.pdf",
            panel: panel(name: "wrong"),
            presentation: "rendered",
            relativePath: "pdf/does-not-exist.pdf",
            byteCount: 3
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(brokenCopy).write(
            to: root.appendingPathComponent("records/0000-broken-copy.json")
        )

        let report = try await disk.loadReport()

        XCTAssertEqual(report.records, [healthy])
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertTrue(report.issues[0].reason.contains("Saved content is missing"))
    }

    @MainActor
    func testArchivedPanelNavigationNeverFollowsAReusedTmuxHandle() {
        let state = AppState(isolatedForTesting: true)
        state.sessionsByMachine["local"] = [
            SessionInfo(
                name: "osworld_pareto2", path: "/Users/me/find_osworld2_pareto",
                tmuxID: "$11", lineageID: "tmux:new"
            ),
        ]
        let archived = panel(
            name: "open_conjecture", stableID: "$11", lineageID: "tmux:old",
            folder: "/Users/me/open_conjectures"
        )

        XCTAssertNil(state.liveRef(for: archived))

        state.sessionsByMachine["local"]?.append(SessionInfo(
            name: "open_conjecture", path: "/Users/me/open_conjectures",
            tmuxID: "$42", lineageID: "tmux:newer"
        ))
        XCTAssertEqual(
            state.liveRef(for: archived),
            SessionRef(machineID: "local", session: "open_conjecture")
        )
    }

    @MainActor
    func testLibraryViewHostsAtMinimumMainPaneWidth() async throws {
        let disk = ArtifactDiskStore(rootURL: root)
        let sampleView = NSView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        let samplePDF = sampleView.dataWithPDF(inside: sampleView.bounds)
        _ = try await disk.savePDF(
            samplePDF,
            panel: panel(name: "vlm_gating", stableID: "$7"),
            presentation: "rendered",
            createdAt: Date(timeIntervalSinceNow: -3_600)
        )
        _ = try await disk.savePDF(
            samplePDF,
            panel: panel(name: "spatial_fable", stableID: "$8"),
            presentation: "terminal",
            createdAt: Date()
        )
        _ = try await disk.saveScreenshotPNG(
            samplePNG(),
            panel: panel(name: "vlm_gating", stableID: "$7"),
            createdAt: Date(timeIntervalSinceNow: 2)
        )
        _ = try await disk.saveFile(
            Data("# Saved decision\n\nKeep the current result.\n".utf8),
            filename: "decision.md",
            panel: panel(name: "spatial_sol", stableID: "$8"),
            sourcePath: "/tmp/work/decision.md",
            contentType: "text/markdown",
            presentation: "file-draft",
            createdAt: Date(timeIntervalSinceNow: 3)
        )
        let store = ArtifactStore(rootURL: root, loadImmediately: false, logEvents: false)
        await store.reload()
        switch ProcessInfo.processInfo.environment["UT_ARTIFACT_SCREENSHOT_MODE"] {
        case "panel":
            if let context = store.records.first?.panel { store.open(panel: context) }
        case "viewer":
            if let record = store.records.first { store.open(artifact: record) }
        case "file-viewer":
            if let record = store.records.first(where: { $0.kind == ArtifactKind.fileSnapshot }) {
                store.open(artifact: record)
            }
        default:
            break
        }
        let host = NSHostingView(rootView: ArtifactsView()
            .environmentObject(AppState(isolatedForTesting: true))
            .environmentObject(store))
        host.frame = NSRect(x: 0, y: 0, width: 708, height: 700)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)

        // Optional local visual QA without making screenshot files a normal
        // test side effect.
        if let path = ProcessInfo.processInfo.environment["UT_ARTIFACT_SCREENSHOT"] {
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func panel(
        name: String = "spatial_sol",
        stableID: String? = "$4",
        lineageID: String? = nil,
        machineID: String = "local",
        machineName: String = "this mac",
        machineHost: String = "mac.local",
        folder: String = "/tmp/work"
    ) -> ArtifactPanelContext {
        ArtifactPanelContext(
            machineID: machineID,
            machineName: machineName,
            machineHost: machineHost,
            sessionName: name,
            stableSessionID: stableID,
            sessionLineageID: lineageID,
            folder: folder
        )
    }

    private func samplePNG() -> Data {
        let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.88, alpha: 1).setFill()
            NSRect(x: 36, y: 42, width: rect.width - 72, height: 8).fill()
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    @MainActor
    private func waitForArtifact(
        in store: ArtifactStore,
        id: UUID,
        predicate: (ArtifactRecord) -> Bool
    ) async -> ArtifactRecord? {
        for _ in 0..<200 {
            if let record = store.records.first(where: { $0.id == id }), predicate(record) {
                return record
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return store.records.first(where: { $0.id == id })
    }

    private func record(
        filename: String,
        seconds: TimeInterval,
        id: String = UUID().uuidString,
        panel: ArtifactPanelContext? = nil
    ) -> ArtifactRecord {
        let uuid = UUID(uuidString: id)!
        return ArtifactRecord(
            id: uuid,
            filename: filename,
            createdAt: Date(timeIntervalSince1970: seconds),
            panel: panel ?? self.panel(name: "other"),
            presentation: "rendered",
            relativePath: "pdf/" + uuid.uuidString.lowercased() + ".pdf",
            byteCount: 3
        )
    }
}

private actor FixedArtifactTitleProvider: ArtifactTitleProviding {
    let value: String

    init(_ value: String) { self.value = value }

    func title(for request: ArtifactTitleRequest) async -> String? { value }
}

private actor DeferredArtifactTitleProvider: ArtifactTitleProviding {
    private var started = false
    private var continuation: CheckedContinuation<String?, Never>?

    func title(for request: ArtifactTitleRequest) async -> String? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func didStart() -> Bool { started }

    func finish(with value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
