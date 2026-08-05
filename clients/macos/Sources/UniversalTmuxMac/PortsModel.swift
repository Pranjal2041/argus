import Foundation

/// One active local-port → remote-broker tunnel (mirrors the broker's JSON).
struct PortForward: Codable, Identifiable {
    let id: String
    let brokerHost: String
    let brokerName: String
    let scheme: String
    let remotePort: Int
    let localPort: Int
    let label: String
}

/// A listening port on a host, from a broker's /ports.
struct PortInfo: Codable, Identifiable {
    let port: Int
    let address: String
    let process: String
    let pid: Int
    var web: Bool = false   // set by /ports?probe=1 — the port answered an HTTP request
    var id: Int { port }

    private enum CodingKeys: String, CodingKey {
        case port, address, process, pid, web
    }

    init(port: Int, address: String, process: String, pid: Int, web: Bool = false) {
        self.port = port
        self.address = address
        self.process = process
        self.pid = pid
        self.web = web
    }

    // Go omits `web` when it is false. Swift's synthesized decoder does not
    // apply the property default for a missing key; it rejects the entire
    // response instead. That made every normal `/ports` response look empty.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        port = try values.decode(Int.self, forKey: .port)
        address = try values.decode(String.self, forKey: .address)
        process = try values.decode(String.self, forKey: .process)
        pid = try values.decode(Int.self, forKey: .pid)
        web = try values.decodeIfPresent(Bool.self, forKey: .web) ?? false
    }
}

/// A remembered forward config, persisted for one-click re-run.
struct SavedForward: Codable, Identifiable, Hashable {
    let brokerHost: String
    let brokerName: String
    let scheme: String
    let remotePort: Int
    let label: String
    var id: String { "\(brokerHost)#\(remotePort)#\(label)" }
}

/// Drives the port hub: talks to the local Mac broker's agent (/forwards) and
/// each broker's /ports. All forwarding happens in the broker (Go); this is UI.
final class PortsModel: ObservableObject {
    @Published var active: [PortForward] = []
    @Published var saved: [SavedForward] = []
    @Published var portsByHost: [String: [PortInfo]] = [:]   // brokerHost -> listening ports
    @Published var portErrorsByHost: [String: String] = [:]
    @Published var loadingPortsFor: String? = nil

    /// The local Mac broker is the forward agent.
    private let agent = "http://127.0.0.1:8722"
    private let prefs = UserDefaults.standard
    private var timer: Timer?

    init() {
        loadSaved()
        refreshActive()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshActive() }
    }

    func refreshActive() {
        guard let url = URL(string: agent + "/forwards") else { return }
        brokerSession.dataTask(with: url) { data, _, _ in
            guard let data, let r = try? JSONDecoder().decode(ForwardsResp.self, from: data) else { return }
            DispatchQueue.main.async { self.active = r.forwards ?? [] }
        }.resume()
    }

    /// Fetch a host's listening ports (uses that broker's own base URL/scheme).
    func fetchPorts(host: String, base: String) {
        guard let url = URL(string: base + "/ports") else {
            portErrorsByHost[host] = "This broker has an invalid address."
            return
        }
        loadingPortsFor = host
        portErrorsByHost[host] = nil
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        brokerSession.dataTask(with: request) { data, response, error in
            let result: Result<[PortInfo], Error>
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw PortDiscoveryError.badResponse
                }
                guard let data else { throw PortDiscoveryError.badResponse }
                result = .success(try PortListDecoder.decode(data))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let ports):
                    self.portsByHost[host] = ports
                    self.portErrorsByHost[host] = nil
                case .failure(let error):
                    // Keep the last good list on a transient failure. An empty
                    // state must mean the broker returned zero listeners, not
                    // that networking or decoding failed.
                    self.portErrorsByHost[host] = (error as? PortDiscoveryError)?.errorDescription
                        ?? "Could not reach this broker. Refresh to retry."
                }
                if self.loadingPortsFor == host { self.loadingPortsFor = nil }
            }
        }.resume()
    }

    func start(host: String, name: String, scheme: String, remotePort: Int, label: String) {
        var comps = URLComponents(string: agent + "/forwards")!
        comps.queryItems = [
            .init(name: "brokerHost", value: host),
            .init(name: "brokerName", value: name),
            .init(name: "scheme", value: scheme),
            .init(name: "remotePort", value: String(remotePort)),
            .init(name: "localPort", value: String(remotePort)), // preferred; agent bumps if busy
            .init(name: "label", value: label),
        ]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        brokerSession.dataTask(with: req) { _, _, _ in
            DispatchQueue.main.async {
                self.refreshActive()
                let s = SavedForward(brokerHost: host, brokerName: name, scheme: scheme, remotePort: remotePort, label: label)
                if !self.saved.contains(where: { $0.id == s.id }) { self.saved.insert(s, at: 0); self.saveSaved() }
            }
        }.resume()
    }

    func stop(_ id: String) {
        var comps = URLComponents(string: agent + "/forwards")!
        comps.queryItems = [.init(name: "id", value: id)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"
        brokerSession.dataTask(with: req) { _, _, _ in DispatchQueue.main.async { self.refreshActive() } }.resume()
    }

    func run(_ s: SavedForward) { start(host: s.brokerHost, name: s.brokerName, scheme: s.scheme, remotePort: s.remotePort, label: s.label) }
    func removeSaved(_ s: SavedForward) { saved.removeAll { $0.id == s.id }; saveSaved() }
    func activeFor(_ s: SavedForward) -> PortForward? { active.first { $0.brokerHost == s.brokerHost && $0.remotePort == s.remotePort } }

    private func loadSaved() {
        if let d = prefs.data(forKey: "saved_forwards"), let s = try? JSONDecoder().decode([SavedForward].self, from: d) { saved = s }
    }
    private func saveSaved() {
        if let d = try? JSONEncoder().encode(saved) { prefs.set(d, forKey: "saved_forwards") }
    }
}

private struct ForwardsResp: Codable { let forwards: [PortForward]? }
struct PortsResp: Codable { let ports: [PortInfo]? }

enum PortListDecoder {
    static func decode(_ data: Data) throws -> [PortInfo] {
        try JSONDecoder().decode(PortsResp.self, from: data).ports?.sorted { $0.port < $1.port } ?? []
    }
}

private enum PortDiscoveryError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        "The broker returned an invalid port list."
    }
}
