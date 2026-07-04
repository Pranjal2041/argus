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
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let r = try? JSONDecoder().decode(ForwardsResp.self, from: data) else { return }
            DispatchQueue.main.async { self.active = r.forwards ?? [] }
        }.resume()
    }

    /// Fetch a host's listening ports (uses that broker's own base URL/scheme).
    func fetchPorts(host: String, base: String) {
        guard let url = URL(string: base + "/ports") else { return }
        DispatchQueue.main.async { self.loadingPortsFor = host }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let ports = (data.flatMap { try? JSONDecoder().decode(PortsResp.self, from: $0) }?.ports ?? [])
                .sorted { $0.port < $1.port }
            DispatchQueue.main.async {
                self.portsByHost[host] = ports
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
        URLSession.shared.dataTask(with: req) { _, _, _ in
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
        URLSession.shared.dataTask(with: req) { _, _, _ in DispatchQueue.main.async { self.refreshActive() } }.resume()
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
private struct PortsResp: Codable { let ports: [PortInfo]? }
