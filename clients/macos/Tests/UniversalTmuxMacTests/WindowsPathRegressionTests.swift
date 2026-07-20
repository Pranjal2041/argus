import XCTest
@testable import UniversalTmuxMac

final class WindowsPathRegressionTests: XCTestCase {
    func testSlashPrefixedWindowsDrivePathBecomesAbsolute() {
        XCTAssertEqual(
            normalizedTerminalPath("/D:/gym_anything_for_robotics/ATOMIC_PRIMITIVE_COLLECTION_PLAN.md", remoteOS: "windows"),
            "D:/gym_anything_for_robotics/ATOMIC_PRIMITIVE_COLLECTION_PLAN.md"
        )
        XCTAssertEqual(
            normalizedTerminalPath(#"\D:\work\plan.md"#, remoteOS: "WINDOWS"),
            #"D:\work\plan.md"#
        )
    }

    func testWindowsNormalizationLeavesOtherPathFormsAlone() {
        XCTAssertEqual(normalizedTerminalPath(#"D:\work\plan.md"#, remoteOS: "windows"), #"D:\work\plan.md"#)
        XCTAssertEqual(normalizedTerminalPath(#"\\server\share\plan.md"#, remoteOS: "windows"), #"\\server\share\plan.md"#)
        XCTAssertEqual(normalizedTerminalPath(#"\rooted\plan.md"#, remoteOS: "windows"), #"\rooted\plan.md"#)
    }

    func testPosixHostMayKeepLiteralDriveNamedRootDirectory() {
        XCTAssertEqual(normalizedTerminalPath("/D:/work/plan.md", remoteOS: "linux"), "/D:/work/plan.md")
    }
}
