import XCTest
@testable import UniversalTmuxMac

final class WorkspaceSidebarSizingTests: XCTestCase {
    func testSidebarWidthIsClampedToUsableBounds() {
        XCTAssertEqual(WorkspaceSidebarSizing.clamped(100), WorkspaceSidebarSizing.minimumWidth)
        XCTAssertEqual(WorkspaceSidebarSizing.clamped(340), 340)
        XCTAssertEqual(WorkspaceSidebarSizing.clamped(900), WorkspaceSidebarSizing.maximumWidth)
    }
}
