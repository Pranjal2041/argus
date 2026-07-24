import XCTest
@testable import UniversalTmuxMac

final class BrokerDiscoveryTests: XCTestCase {
    func testProbeOrderBypassesStaleDNSWithoutSendingHTTPToDNSName() {
        let attempts = brokerProbeAttempts(
            dns: "ut-babel-p9-16.example.ts.net",
            ips: ["100.71.56.4", "fd7a:115c:a1e0::1"]
        )

        XCTAssertEqual(attempts, [
            BrokerProbeAttempt(scheme: "https", address: "ut-babel-p9-16.example.ts.net"),
            BrokerProbeAttempt(scheme: "http", address: "100.71.56.4"),
            BrokerProbeAttempt(scheme: "http", address: "fd7a:115c:a1e0::1"),
        ])
        XCTAssertFalse(attempts.contains {
            $0.scheme == "http" && $0.address == "ut-babel-p9-16.example.ts.net"
        })
    }

    func testLegacyPeerWithoutIPsRetainsHTTPFallback() {
        XCTAssertEqual(brokerProbeAttempts(dns: "old-peer.example.ts.net", ips: []), [
            BrokerProbeAttempt(scheme: "https", address: "old-peer.example.ts.net"),
            BrokerProbeAttempt(scheme: "http", address: "old-peer.example.ts.net"),
        ])
    }

    func testBrokerRouteRegistryAndIPv6URLFormatting() {
        registerBrokerTLSAddress("fd7a:115c:a1e0::1", dnsName: "ut-peer.example.ts.net")
        XCTAssertEqual(brokerRouteAddress(for: "ut-peer.example.ts.net"), "fd7a:115c:a1e0::1")
        registerBrokerTLSAddress("100.71.56.4", dnsName: "ut-peer.example.ts.net")
        XCTAssertEqual(brokerRouteAddress(for: "ut-peer.example.ts.net"), "100.71.56.4")
        XCTAssertEqual(brokerURLHost("fd7a:115c:a1e0::1"), "[fd7a:115c:a1e0::1]")
        XCTAssertEqual(brokerURLHost("100.71.56.4"), "100.71.56.4")
    }
}
