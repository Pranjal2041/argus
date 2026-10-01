import XCTest
@testable import Argus

final class BrokerProtocolTests: XCTestCase {
    func testFrameRoundTripAndInputChunking() throws {
        let frames = WireFrame.encode(op: Op.input, pane: "%3", payload: Array(repeating: 0x61, count: 9000))
        XCTAssertEqual(frames.map(\.count), [2 + 2 + 4096, 2 + 2 + 4096, 2 + 2 + 808])
        let first = try XCTUnwrap(WireFrame.decode(frames[0]))
        XCTAssertEqual(first.op, Op.input)
        XCTAssertEqual(first.pane, "%3")
        XCTAssertEqual(first.payload.count, 4096)
        // Control frames carry no payload but are still well-formed.
        XCTAssertEqual(WireFrame.encode(op: Op.requestSnapshot), [Data([Op.requestSnapshot, 0])])
    }

    func testResizeAndPaneSizeAreBigEndianU16() throws {
        XCTAssertEqual(WireFrame.resize(cols: 300, rows: 50), Data([Op.resize, 0, 0x01, 0x2c, 0x00, 0x32]))
        let pane = try XCTUnwrap(WireFrame.decode(Data([Op.paneSize, 0, 0x00, 0x50, 0x00, 0x18])))
        let size = try XCTUnwrap(WireFrame.paneSize(pane.payload))
        XCTAssertEqual(size.cols, 80)
        XCTAssertEqual(size.rows, 24)
        XCTAssertNil(WireFrame.paneSize([0, 0, 0, 24]))
        XCTAssertNil(WireFrame.decode(Data([Op.output, 5, 1])))   // truncated pane name
    }

    func testMeshPeersMapLikeTheMacClient() throws {
        let json = """
        {"peers":[
          {"name":"babel-s9-20","host":"ut-babel-s9-20.tailnet.ts.net","scheme":"https","os":"linux",
           "tailnetName":"ut-babel-s9-20.tailnet.ts.net","address":"100.64.0.9"},
          {"name":"","host":"100.64.0.7","scheme":"http","os":"windows"},
          {"name":"bad","host":"100.64.0.8","scheme":"ftp"}
        ]}
        """
        struct R: Decodable { let peers: [MeshPeer] }
        let machines = try JSONDecoder().decode(R.self, from: Data(json.utf8)).peers.compactMap(Machine.from)
        XCTAssertEqual(machines.count, 2)
        XCTAssertEqual(machines[0].httpBase.absoluteString, "https://ut-babel-s9-20.tailnet.ts.net:8722")
        XCTAssertEqual(machines[0].wsBase.absoluteString, "wss://ut-babel-s9-20.tailnet.ts.net:8722")
        XCTAssertEqual(machines[1].name, "100.64.0.7")
        XCTAssertEqual(machines[1].wsBase.absoluteString, "ws://100.64.0.7:8722")
    }

    func testSessionsFailClosedAndUseTheStableHandle() throws {
        let json = """
        {"sessions":[{"name":"train","state":"working","agent":false,"id":"$4"},{"name":"old-broker"}]}
        """
        struct R: Decodable { let sessions: [SessionInfo] }
        let s = try JSONDecoder().decode(R.self, from: Data(json.utf8)).sessions
        XCTAssertEqual(s[0].handle, "$4")
        XCTAssertTrue(s[0].isForeground)
        XCTAssertTrue(s[1].agent, "a missing agent field is background")
        XCTAssertEqual(s[1].handle, "old-broker")
    }

    func testAttentionSectionsPreferTheModelLabel() {
        XCTAssertEqual(AttentionSection.of(label: "stuck", state: "working"), .needsYou)
        XCTAssertEqual(AttentionSection.of(label: "milestone", state: "waiting"), .idle)
        XCTAssertEqual(AttentionSection.of(label: nil, state: "waiting"), .needsYou)
        XCTAssertEqual(AttentionSection.of(label: nil, state: "working"), .working)
        XCTAssertEqual(AttentionSection.of(label: nil, state: nil), .idle)
    }
}
