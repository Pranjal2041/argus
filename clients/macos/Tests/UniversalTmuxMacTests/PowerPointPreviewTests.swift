import Foundation
import XCTest
@testable import UniversalTmuxMac

final class PowerPointPreviewTests: XCTestCase {
    func testPowerPointFamiliesUseQuickLookRegardlessOfDeckSize() {
        for ext in ["pptx", "PPT", "ppsx", "pps", "potx", "pot"] {
            XCTAssertEqual(
                fileKindForPreview("deck.\(ext)", size: 750_000_000),
                .quickLook,
                "\(ext) should remain previewable above the text-memory cap"
            )
        }
        XCTAssertEqual(fileKindForPreview("archive.zip", size: 750_000_000), .binary)
    }

    func testQuickLookLeasePreservesExtensionAndDeletesCacheOnRelease() throws {
        let fm = FileManager.default
        let sourceDirectory = fm.temporaryDirectory
            .appendingPathComponent("PowerPointPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sourceDirectory) }

        let source = sourceDirectory.appendingPathComponent("download")
        let expected = Data("pptx fixture bytes".utf8)
        try expected.write(to: source)

        var preview: QuickLookPreviewFile? = try QuickLookPreviewFile(
            adopting: source,
            filename: "research-deck.pptx"
        )
        let cachedURL = try XCTUnwrap(preview?.url)
        let cachedDirectory = cachedURL.deletingLastPathComponent()

        XCTAssertEqual(cachedURL.pathExtension, "pptx")
        XCTAssertEqual(try Data(contentsOf: cachedURL), expected)
        XCTAssertTrue(fm.fileExists(atPath: cachedURL.path))

        preview = nil
        XCTAssertFalse(fm.fileExists(atPath: cachedDirectory.path))
    }
}
