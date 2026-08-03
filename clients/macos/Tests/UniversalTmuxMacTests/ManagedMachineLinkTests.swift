import Foundation
import XCTest
@testable import UniversalTmuxMac

final class ManagedMachineLinkTests: XCTestCase {
    func testPrintedMachineURLPreservesForwardingTarget() throws {
        let url = try XCTUnwrap(URL(string: "http://babel-p9-16:5800/dashboard?view=workers%20now#live"))
        let target = try XCTUnwrap(terminalDashboardLink(from: url))

        XCTAssertEqual(target.host, "babel-p9-16")
        XCTAssertEqual(target.port, 5800)
        XCTAssertEqual(target.path, "/dashboard?view=workers%20now#live")
        XCTAssertEqual(target.scheme, "http")
        XCTAssertFalse(target.isLoopback)
    }

    func testLoopbackURLKeepsExistingCurrentMachineRoute() throws {
        let url = try XCTUnwrap(URL(string: "https://localhost/healthz"))
        let target = try XCTUnwrap(terminalDashboardLink(from: url))

        XCTAssertEqual(target.port, 443)
        XCTAssertEqual(target.path, "/healthz")
        XCTAssertTrue(target.isLoopback)
    }

    func testShortBrokerHostnameResolvesDiscoveredMachine() throws {
        let babel = machine(
            id: "ut-babel-p9-16.tailnet.example.ts.net",
            name: "babel-p9-16",
            host: "babel-p9-16",
            address: "100.70.80.90"
        )

        let match = try XCTUnwrap(machineForManagedLinkHost("BABEL-P9-16.", in: [babel]))
        XCTAssertEqual(match.id, babel.id)
    }

    func testDiscoveryDNSNameAndAddressResolveExactly() throws {
        let babel = machine(
            id: "ut-babel-p9-16.tailnet.example.ts.net",
            name: "babel-p9-16",
            host: "babel-p9-16",
            address: "100.70.80.90"
        )

        XCTAssertEqual(
            machineForManagedLinkHost("ut-babel-p9-16.tailnet.example.ts.net", in: [babel])?.id,
            babel.id
        )
        XCTAssertEqual(machineForManagedLinkHost("100.70.80.90", in: [babel])?.id, babel.id)
    }

    func testUnrelatedDomainWithSameFirstLabelIsNotCaptured() {
        let babel = machine(
            id: "ut-babel-p9-16.tailnet.example.ts.net",
            name: "babel-p9-16",
            host: "babel-p9-16",
            address: "100.70.80.90"
        )

        XCTAssertNil(machineForManagedLinkHost("babel-p9-16.example.com", in: [babel]))
    }

    func testAmbiguousShortHostnameIsNotRouted() {
        let first = machine(
            id: "ut-worker.cluster-one.example.ts.net",
            name: "cluster-one-worker",
            host: "worker",
            address: "100.70.80.91"
        )
        let second = machine(
            id: "ut-worker.cluster-two.example.ts.net",
            name: "cluster-two-worker",
            host: "worker",
            address: "100.70.80.92"
        )

        XCTAssertNil(machineForManagedLinkHost("worker", in: [first, second]))
        XCTAssertEqual(
            machineForManagedLinkHost("ut-worker.cluster-one.example.ts.net", in: [first, second])?.id,
            first.id
        )
    }

    private func machine(id: String, name: String, host: String, address: String) -> Machine {
        Machine(
            id: id,
            name: name,
            host: host,
            os: "linux",
            isLocal: false,
            httpBase: "https://\(address):8722",
            wsBase: "wss://\(address):8722"
        )
    }
}
