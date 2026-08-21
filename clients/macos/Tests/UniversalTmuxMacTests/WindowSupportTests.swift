import AppKit
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class WindowSupportTests: XCTestCase {
    func testFullScreenCapabilityIsRestoredAfterWindowReconfiguration() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let enabler = FullScreenEnablerView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = enabler
        await Task.yield()

        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        enabler.refresh()
        await Task.yield()

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
