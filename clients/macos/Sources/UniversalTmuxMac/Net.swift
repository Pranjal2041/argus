import CFNetwork
import Foundation
import Network

/// A tiny loopback CONNECT proxy used only by broker HTTPS traffic. URLSession
/// still connects to `ut-*.ts.net`, so TLS sends the correct SNI and performs its
/// normal certificate validation; the proxy changes only the socket destination
/// to the authoritative IP already reported by Tailscale. This avoids macOS's
/// occasionally stale negative MagicDNS cache without weakening TLS.
private final class BrokerHTTPSProxy {
    static let shared = BrokerHTTPSProxy()

    private let queue = DispatchQueue(label: "ut.broker-https-proxy")
    private let routeLock = NSLock()
    private var routes: [String: String] = [:]
    private var listener: NWListener?
    private var tunnels: [ObjectIdentifier: BrokerProxyTunnel] = [:]
    private(set) var port: UInt16?

    private init() {
        let ready = DispatchSemaphore(value: 0)
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    self?.port = listener?.port?.rawValue
                    ready.signal()
                case .failed:
                    ready.signal()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 2)
        } catch {
            listener = nil
        }
    }

    func register(dnsName: String, address: String) {
        let key = Self.normalized(dnsName)
        routeLock.lock()
        routes[key] = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        routeLock.unlock()
    }

    func address(for dnsName: String) -> String? {
        routeLock.lock()
        defer { routeLock.unlock() }
        return routes[Self.normalized(dnsName)]
    }

    func apply(to configuration: URLSessionConfiguration) {
        guard let port else { return }
        var proxies = configuration.connectionProxyDictionary ?? [:]
        proxies[kCFNetworkProxiesHTTPSEnable as String] = 1
        proxies[kCFNetworkProxiesHTTPSProxy as String] = "127.0.0.1"
        proxies[kCFNetworkProxiesHTTPSPort as String] = Int(port)
        configuration.connectionProxyDictionary = proxies
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private func accept(_ connection: NWConnection) {
        var id: ObjectIdentifier!
        let tunnel = BrokerProxyTunnel(
            client: connection,
            queue: queue,
            resolve: { [weak self] host in self?.address(for: host) ?? host },
            onClose: { [weak self] in
                guard let self, let id else { return }
                self.queue.async { self.tunnels.removeValue(forKey: id) }
            }
        )
        id = ObjectIdentifier(tunnel)
        tunnels[id] = tunnel
        tunnel.start()
    }
}

private final class BrokerProxyTunnel {
    private let client: NWConnection
    private let queue: DispatchQueue
    private let resolve: (String) -> String
    private let onClose: () -> Void
    private var upstream: NWConnection?
    private var request = Data()
    private var closed = false

    init(client: NWConnection, queue: DispatchQueue,
         resolve: @escaping (String) -> String, onClose: @escaping () -> Void) {
        self.client = client
        self.queue = queue
        self.resolve = resolve
        self.onClose = onClose
    }

    func start() {
        client.start(queue: queue)
        receiveRequest()
    }

    private func receiveRequest() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, complete, error in
            guard let self, !closed else { return }
            if let data { request.append(data) }
            guard request.count <= 64 * 1024, error == nil, !complete else {
                finish()
                return
            }
            let separator = Data("\r\n\r\n".utf8)
            guard let headerEnd = request.range(of: separator) else {
                receiveRequest()
                return
            }
            let header = request[..<headerEnd.lowerBound]
            let remainder = Data(request[headerEnd.upperBound...])
            guard let firstLine = String(data: header, encoding: .utf8)?.split(separator: "\r\n").first,
                  firstLine.hasPrefix("CONNECT ") else {
                reject()
                return
            }
            let fields = firstLine.split(separator: " ")
            guard fields.count >= 2,
                  let target = URLComponents(string: "https://" + fields[1]).flatMap({ components in
                      components.host.map { ($0, components.port ?? 443) }
                  }),
                  let port = NWEndpoint.Port(rawValue: UInt16(target.1)) else {
                reject()
                return
            }
            connect(address: resolve(target.0), port: port, remainder: remainder)
        }
    }

    private func connect(address: String, port: NWEndpoint.Port, remainder: Data) {
        let upstream = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self, weak upstream] state in
            guard let self, let upstream, !closed else { return }
            switch state {
            case .ready:
                upstream.stateUpdateHandler = nil
                let response = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(content: response, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil, !closed else { self?.finish(); return }
                    let begin = {
                        self.pump(from: self.client, to: upstream)
                        self.pump(from: upstream, to: self.client)
                    }
                    if remainder.isEmpty {
                        begin()
                    } else {
                        upstream.send(content: remainder, completion: .contentProcessed { error in
                            error == nil ? begin() : self.finish()
                        })
                    }
                })
            case .failed, .cancelled:
                reject()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !closed else { return }
            guard error == nil, !complete, let data, !data.isEmpty else {
                finish()
                return
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil, !closed else { self?.finish(); return }
                pump(from: source, to: destination)
            })
        }
    }

    private func reject() {
        guard !closed else { return }
        client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        onClose()
    }
}

private func brokerConfiguration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
    BrokerHTTPSProxy.shared.apply(to: configuration)
    return configuration
}

/// All broker calls share the normal URLSession behavior. HTTPS alone is sent
/// through the loopback tunnel above; plain loopback/native-broker HTTP is direct.
let brokerSession = URLSession(configuration: brokerConfiguration(.default))

func makeBrokerSession(configuration: URLSessionConfiguration) -> URLSession {
    URLSession(configuration: brokerConfiguration(configuration))
}

func registerBrokerTLSAddress(_ address: String, dnsName: String) {
    BrokerHTTPSProxy.shared.register(dnsName: dnsName, address: address)
}

func brokerRouteAddress(for dnsName: String) -> String? {
    BrokerHTTPSProxy.shared.address(for: dnsName)
}
