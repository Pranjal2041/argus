import Foundation
import XCTest
@testable import UniversalTmuxMac

final class PortsModelTests: XCTestCase {
    func testNormalBrokerResponseDecodesWhenWebFlagIsOmitted() throws {
        let data = Data(#"{"ports":[{"port":4173,"address":"127.0.0.1","process":"python.exe","pid":32188}]}"#.utf8)

        let ports = try PortListDecoder.decode(data)

        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].port, 4173)
        XCTAssertEqual(ports[0].process, "python.exe")
        XCTAssertFalse(ports[0].web)
    }

    func testProbedResponsePreservesWebFlagAndSortsPorts() throws {
        let data = Data(#"{"ports":[{"port":8797,"address":"127.0.0.1","process":"python.exe","pid":2,"web":true},{"port":4173,"address":"127.0.0.1","process":"python.exe","pid":1}]}"#.utf8)

        let ports = try PortListDecoder.decode(data)

        XCTAssertEqual(ports.map(\.port), [4173, 8797])
        XCTAssertEqual(ports.map(\.web), [false, true])
    }
}
