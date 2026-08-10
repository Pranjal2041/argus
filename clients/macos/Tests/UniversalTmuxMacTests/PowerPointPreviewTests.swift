import AppKit
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

    /// Regression for the production crash: QLPreviewView aborts if an item is
    /// assigned after its NSWindow closes. The host must discard that deactivated
    /// child during `willClose` and allocate a different one on reopening.
    @MainActor
    func testQuickLookHostUsesFreshPreviewAfterWindowCloseAndReopen() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("QuickLookWindowLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let itemURL = directory.appendingPathComponent("preview.txt")
        try Data("Quick Look lifecycle fixture".utf8).write(to: itemURL)

        let host = QuickLookPreviewHostView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 320)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.show(itemURL)
        let firstPreview = try XCTUnwrap(host.activePreviewView)

        window.close()
        XCTAssertNil(host.activePreviewView, "The child must be discarded before Quick Look deactivates it")

        window.makeKeyAndOrderFront(nil)
        host.show(itemURL) // mirrors SwiftUI updateNSView during openWindow(id:)
        let reopenedPreview = try XCTUnwrap(host.activePreviewView)

        XCTAssertFalse(firstPreview === reopenedPreview, "A deactivated QLPreviewView must never be reused")
        window.close()
        host.invalidate()
    }
}
