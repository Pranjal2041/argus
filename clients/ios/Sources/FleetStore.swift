import Foundation
import SwiftUI

/// The phone's view of the fleet. The iPhone joins the tailnet through the
/// Tailscale app; Argus asks one "hub" broker (normally your Mac) for its
/// `/mesh/peers`, exactly as the macOS app asks its local broker, and then
/// talks to every broker directly.
@MainActor
final class FleetStore: ObservableObject {
    static let hubKey = "argus.hub"

    @Published var hubAddress: String = UserDefaults.standard.string(forKey: FleetStore.hubKey) ?? "" {
        didSet { UserDefaults.standard.set(hubAddress, forKey: Self.hubKey) }
    }
    @Published private(set) var machines: [Machine] = []
    @Published private(set) var sessions: [String: [SessionInfo]] = [:]       // machine id → sessions
    @Published private(set) var commandCenter: [String: [String: CommandCenterItem]] = [:] // machine → session → item
    @Published private(set) var reachable: Set<String> = []
    @Published private(set) var hubError: String?
    @Published private(set) var lastRefresh: Date?

    private var loop: Task<Void, Never>?
    private var tick = 0

    var isConfigured: Bool { !hubAddress.trimmingCharacters(in: .whitespaces).isEmpty }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    func refreshNow() async {
        tick = 0
        await step()
    }

    /// Discovery every ~15 s (5 ticks), sessions and Command Center every tick.
    private func step() async {
        guard isConfigured else { return }
        if tick % 5 == 0 || machines.isEmpty { await discover() }
        tick += 1
        await refreshSessions()
        lastRefresh = Date()
    }

    // MARK: Discovery

    private func discover() async {
        do {
            let hub = try await resolveHub(hubAddress)
            let peers = try await BrokerHTTP.get(hub.httpBase, "mesh/peers", as: PeersResponse.self).peers
            var found = [hub]
            for p in peers {
                guard let m = Machine.from(peer: p), !found.contains(where: { $0.id == m.id }) else { continue }
                found.append(m)
            }
            // Merge: keep machines a transient scan missed until they stay unreachable.
            let kept = machines.filter { old in !found.contains { $0.id == old.id } && reachable.contains(old.id) }
            machines = (found + kept).sorted { ($0.isHub ? 0 : 1, $0.name.lowercased()) < ($1.isHub ? 0 : 1, $1.name.lowercased()) }
            hubError = nil
        } catch {
            hubError = "Can't reach the hub at \(hubAddress): \(error.localizedDescription). Is Tailscale connected on this iPhone?"
        }
    }

    private struct PeersResponse: Decodable { let peers: [MeshPeer] }

    /// A hub address is a tailnet name or IP (optionally with a port). Native
    /// brokers (a Mac) serve http; tsnet brokers serve https by MagicDNS name.
    func resolveHub(_ raw: String) async throws -> Machine {
        var host = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["http://", "https://"] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let colon = host.lastIndex(of: ":"), !host.contains("]"), host.filter({ $0 == ":" }).count == 1 {
            host = String(host[..<colon])
        }
        var lastError: Error = BrokerError.notABroker
        for scheme in ["http", "https"] {
            guard let base = URL(string: "\(scheme)://\(host):\(brokerPort)"),
                  let ws = URL(string: "\(scheme == "https" ? "wss" : "ws")://\(host):\(brokerPort)") else { continue }
            do {
                let who = try await BrokerHTTP.get(base, "whoami", as: Whoami.self)
                guard who.isBroker else { throw BrokerError.notABroker }
                return Machine(id: "hub:" + host.lowercased(), name: who.name ?? host, os: who.os ?? "",
                               httpBase: base, wsBase: ws, isHub: true)
            } catch { lastError = error }
        }
        throw lastError
    }

    // MARK: Sessions + Command Center

    private struct SessionsResponse: Decodable { let sessions: [SessionInfo] }
    private struct CCResponse: Decodable { let items: [CommandCenterItem]? }

    private func refreshSessions() async {
        let snapshot = machines
        await withTaskGroup(of: (String, [SessionInfo]?, [CommandCenterItem]?).self) { group in
            for m in snapshot {
                group.addTask {
                    let s = try? await BrokerHTTP.get(m.httpBase, "sessions",
                                                      query: [URLQueryItem(name: "scope", value: "foreground")],
                                                      as: SessionsResponse.self).sessions
                    let cc = try? await BrokerHTTP.get(m.httpBase, "ccstatus", as: CCResponse.self).items
                    return (m.id, s, cc)
                }
            }
            for await (id, s, cc) in group {
                if let s {
                    sessions[id] = s.filter(\.isForeground).sorted { $0.name.lowercased() < $1.name.lowercased() }
                    reachable.insert(id)
                } else {
                    reachable.remove(id)
                }
                if let cc { commandCenter[id] = Dictionary(cc.map { ($0.session, $0) }, uniquingKeysWith: { a, _ in a }) }
            }
        }
    }

    // MARK: Command Center rows

    struct Card: Identifiable, Hashable {
        let machine: Machine
        let session: SessionInfo
        let item: CommandCenterItem?
        var id: String { machine.id + "/" + session.id }
        var section: AttentionSection { .of(label: item?.label, state: session.state) }
    }

    var cards: [Card] {
        machines.flatMap { m in
            (sessions[m.id] ?? []).map { Card(machine: m, session: $0, item: commandCenter[m.id]?[$0.name]) }
        }
        .sorted { ($0.session.activity ?? 0) > ($1.session.activity ?? 0) }
    }

    // MARK: Actions

    func createSession(on m: Machine, name: String) async throws {
        try await BrokerHTTP.post(m.httpBase, "control", query: [
            .init(name: "action", value: "create"), .init(name: "session", value: name),
            .init(name: "kind", value: "visible"),
        ])
        await refreshNow()
    }

    func killSession(_ s: SessionInfo, on m: Machine) async throws {
        try await BrokerHTTP.post(m.httpBase, "control", query: [
            .init(name: "action", value: "kill"), .init(name: "session", value: s.name),
        ])
        await refreshNow()
    }

    /// Manual Command Center status; the Mac applies and republishes it.
    func setStatus(_ label: String, for s: SessionInfo, on m: Machine) async throws {
        try await BrokerHTTP.post(m.httpBase, "ccoverride", query: [
            .init(name: "session", value: s.name), .init(name: "label", value: label),
        ])
    }
}
