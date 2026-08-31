import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

final class AdaptiveContentLayoutTests: XCTestCase {
    func testFileTableColumnsFillSpareViewportWidth() {
        let fitted = FileTableColumnLayout.fitted([120, 180, 100], viewportWidth: 1_000)

        XCTAssertEqual(fitted.reduce(0, +), 1_000, accuracy: 0.001)
        XCTAssertEqual(fitted[1] - fitted[0], 60, accuracy: 0.001)
    }

    func testFileTableColumnsKeepIntrinsicWidthWhenHorizontalScrollIsNeeded() {
        let widths: [CGFloat] = [420, 380, 360]

        XCTAssertEqual(FileTableColumnLayout.fitted(widths, viewportWidth: 900), widths)
    }

    @MainActor
    func testFileTablePreviewRendersAtWideViewport() throws {
        let source = "Project,Status,Latest result\nVLM gating,Running,Training reached step 905\nSpatial UE,Finished,Evaluation verified"
        let host = NSHostingView(rootView: TablePreviewView(text: source, isTSV: false, fontSize: 13))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 480)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.frame.width, 1_200)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = ProcessInfo.processInfo.environment["UT_CAPTURE_ADAPTIVE_FILE_TABLE"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
