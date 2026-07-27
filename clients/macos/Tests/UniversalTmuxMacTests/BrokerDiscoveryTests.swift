import Network
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

    func testProxyReleasesEveryClosedEstablishedTunnel() throws {
        let queue = DispatchQueue(label: "broker-proxy-lifecycle-test")
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "upstream listener ready")
        let connectionLock = NSLock()
        var upstreamConnections: [NWConnection] = []
        listener.newConnectionHandler = { connection in
            connectionLock.lock()
            upstreamConnections.append(connection)
            connectionLock.unlock()
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 2)
        defer {
            listener.cancel()
            connectionLock.lock()
            upstreamConnections.forEach { $0.cancel() }
            connectionLock.unlock()
        }

        guard let upstreamPort = listener.port,
              let proxyPort = brokerProxyListeningPort().flatMap(NWEndpoint.Port.init(rawValue:))
        else {
            return XCTFail("proxy or upstream listener did not bind")
        }
        registerBrokerTLSAddress("127.0.0.1", dnsName: "lifecycle.test")

        for batch in 0..<10 {
            let relayed = expectation(description: "batch \(batch) relayed")
            relayed.expectedFulfillmentCount = 20
            let resultLock = NSLock()
            var badResponses: [String] = []
            var clients: [NWConnection] = []

            for _ in 0..<20 {
                let client = NWConnection(
                    host: "127.0.0.1",
                    port: proxyPort,
                    using: .tcp
                )
                clients.append(client)
                client.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    let request = Data(
                        "CONNECT lifecycle.test:\(upstreamPort.rawValue) HTTP/1.1\r\n\r\n".utf8
                    )
                    client.send(content: request, completion: .contentProcessed { error in
                        guard error == nil else {
                            resultLock.lock()
                            badResponses.append("send failed")
                            resultLock.unlock()
                            client.cancel()
                            relayed.fulfill()
                            return
                        }
                        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
                            data, _, _, _ in
                            let response = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                            if !response.hasPrefix("HTTP/1.1 200") {
                                resultLock.lock()
                                badResponses.append(response)
                                resultLock.unlock()
                            }
                            client.cancel()
                            relayed.fulfill()
                        }
                    })
                }
                client.start(queue: queue)
            }

            wait(for: [relayed], timeout: 5)
            XCTAssertTrue(badResponses.isEmpty, "bad proxy responses: \(badResponses)")
            XCTAssertTrue(
                waitForTunnelCount(0, timeout: 3),
                "batch \(batch) left \(brokerProxyActiveTunnelCount()) retained tunnel(s)"
            )
            clients.forEach { $0.cancel() }
        }
    }

    func testProxyTunnelCountHasAContainmentBound() throws {
        guard let proxyPort = brokerProxyListeningPort().flatMap(NWEndpoint.Port.init(rawValue:))
        else { return XCTFail("proxy listener did not bind") }

        let queue = DispatchQueue(label: "broker-proxy-bound-test")
        let connected = expectation(description: "clients connected")
        connected.expectedFulfillmentCount = 200
        var clients: [NWConnection] = []
        for _ in 0..<200 {
            let client = NWConnection(host: "127.0.0.1", port: proxyPort, using: .tcp)
            clients.append(client)
            client.stateUpdateHandler = { state in
                if case .ready = state { connected.fulfill() }
            }
            client.start(queue: queue)
        }
        wait(for: [connected], timeout: 5)
        XCTAssertLessThanOrEqual(brokerProxyActiveTunnelCount(), 128)
        clients.forEach { $0.cancel() }
        XCTAssertTrue(waitForTunnelCount(0, timeout: 3))
    }

    func testLiveRoutedTLSBrokerSoak() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dns = env["UT_TEST_BROKER_DNS"],
              let address = env["UT_TEST_BROKER_IP"]
        else { throw XCTSkip("live broker not configured") }

        registerBrokerTLSAddress(address, dnsName: dns)
        guard let url = URL(string: "https://\(dns):8722/whoami") else {
            return XCTFail("invalid live broker URL")
        }
        let completed = expectation(description: "live routed requests")
        completed.expectedFulfillmentCount = 500
        let lock = NSLock()
        var failures = 0
        for _ in 0..<500 {
            brokerSession.dataTask(with: url) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode
                if error != nil || status != 200 || data?.isEmpty != false {
                    lock.lock()
                    failures += 1
                    lock.unlock()
                }
                completed.fulfill()
            }.resume()
        }
        wait(for: [completed], timeout: 45)
        XCTAssertEqual(failures, 0)
        XCTAssertLessThanOrEqual(
            brokerProxyActiveTunnelCount(),
            16,
            "real routed requests left an unbounded proxy pool"
        )
    }

    func testLiveRoutedTLSWebSocketSoak() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dns = env["UT_TEST_BROKER_DNS"],
              let address = env["UT_TEST_BROKER_IP"],
              let session = env["UT_TEST_BROKER_SESSION"]
        else { throw XCTSkip("live broker WebSocket not configured") }

        registerBrokerTLSAddress(address, dnsName: dns)
        var components = URLComponents()
        components.scheme = "wss"
        components.host = dns
        components.port = 8722
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        guard let url = components.url else { return XCTFail("invalid live WebSocket URL") }

        let received = expectation(description: "live routed WebSockets")
        received.expectedFulfillmentCount = 100
        let lock = NSLock()
        var failures = 0
        var tasks: [URLSessionWebSocketTask] = []
        for _ in 0..<100 {
            let task = brokerSession.webSocketTask(with: url)
            task.maximumMessageSize = 64 * 1024 * 1024
            tasks.append(task)
            task.resume()
            task.receive { result in
                if case .failure = result {
                    lock.lock()
                    failures += 1
                    lock.unlock()
                }
                task.cancel(with: .normalClosure, reason: nil)
                received.fulfill()
            }
        }
        wait(for: [received], timeout: 45)
        tasks.forEach { $0.cancel(with: .normalClosure, reason: nil) }
        XCTAssertEqual(failures, 0)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, brokerProxyActiveTunnelCount() > 16 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertLessThanOrEqual(
            brokerProxyActiveTunnelCount(),
            16,
            "closed WebSockets left an unbounded proxy pool"
        )
    }

    private func waitForTunnelCount(_ expected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if brokerProxyActiveTunnelCount() == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return brokerProxyActiveTunnelCount() == expected
    }
}
