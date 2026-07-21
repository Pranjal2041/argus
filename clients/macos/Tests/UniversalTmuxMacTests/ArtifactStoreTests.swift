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

    func testStableSessionIdentityGroupsArtifactsAcrossRename() {
        let before = panel(name: "old_name", stableID: "$12")
        let after = panel(name: "new_name", stableID: "$12")
        XCTAssertEqual(before.key, after.key)

        let records = [
            record(filename: "Before.pdf", seconds: 100, panel: before),
            record(filename: "After.pdf", seconds: 200, panel: after),
        ]
        let groups = ArtifactLibraryQuery.panels(records)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[0].context.sessionName, "new_name")
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

    private func panel(name: String = "spatial_sol", stableID: String? = "$4") -> ArtifactPanelContext {
        ArtifactPanelContext(
            machineID: "local",
            machineName: "this mac",
            machineHost: "mac.local",
            sessionName: name,
            stableSessionID: stableID,
            folder: "/tmp/work"
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
