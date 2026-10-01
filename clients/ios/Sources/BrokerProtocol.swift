import Foundation

// The broker wire contract, as used by the macOS and Android clients.
// See internal/broker/broker.go (frames), internal/session/session.go (sessions)
// and internal/mesh/mesh.go (peers).

let brokerPort = 8722

enum Op {
    static let output: UInt8 = 1          // broker → client: terminal bytes
    static let input: UInt8 = 2           // client → broker: keystrokes
    static let resize: UInt8 = 3          // client → broker: requested cols×rows
    static let requestSnapshot: UInt8 = 4 // client → broker: fresh authoritative repaint
    static let paneSize: UInt8 = 5        // broker → client: AUTHORITATIVE cols×rows
}

/// `[op u8][paneLen u8][pane][payload]`. Input is chunked to 4 KiB per frame
/// (below the broker's and tmux's per-message limits), like the macOS client.
enum WireFrame {
    static let maxInputPayloadBytes = 4 * 1024

    static func encode(op: UInt8, pane: String = "", payload: [UInt8] = []) -> [Data] {
        let paneBytes = Array(pane.utf8)
        guard paneBytes.count <= Int(UInt8.max) else { return [] }
        func frame(_ slice: ArraySlice<UInt8>) -> Data {
            var bytes: [UInt8] = [op, UInt8(paneBytes.count)]
            bytes.reserveCapacity(2 + paneBytes.count + slice.count)
            bytes += paneBytes
            bytes += slice
            return Data(bytes)
        }
        guard !payload.isEmpty else { return [frame([])] }
        let chunk = op == Op.input ? maxInputPayloadBytes : payload.count
        return stride(from: 0, to: payload.count, by: chunk).map {
            frame(payload[$0..<min($0 + chunk, payload.count)])
        }
    }

    static func resize(cols: Int, rows: Int) -> Data {
        let c = UInt16(clamping: cols), r = UInt16(clamping: rows)
        return encode(op: Op.resize, payload: [UInt8(c >> 8), UInt8(c & 0xff), UInt8(r >> 8), UInt8(r & 0xff)])[0]
    }

    struct Decoded: Equatable {
        let op: UInt8
        let pane: String
        let payload: ArraySlice<UInt8>
    }

    static func decode(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let paneLen = Int(bytes[1])
        guard bytes.count >= 2 + paneLen else { return nil }
        let pane = String(decoding: bytes[2..<(2 + paneLen)], as: UTF8.self)
        return Decoded(op: bytes[0], pane: pane, payload: bytes[(2 + paneLen)...])
    }

    /// PANE_SIZE payload: `cols u16 BE, rows u16 BE`.
    static func paneSize(_ payload: ArraySlice<UInt8>) -> (cols: Int, rows: Int)? {
        guard payload.count >= 4 else { return nil }
        let b = Array(payload.prefix(4))
        let cols = Int(b[0]) << 8 | Int(b[1]), rows = Int(b[2]) << 8 | Int(b[3])
        return cols > 0 && rows > 0 ? (cols, rows) : nil
    }
}

// MARK: Models

struct Whoami: Decodable {
    let service: String
    let name: String?
    let host: String?
    let socket: String?
    let os: String?
    var isBroker: Bool { service == "universal-tmux-broker" }
}

struct MeshPeer: Decodable {
    let name: String?
    let host: String?
    let scheme: String?
    let os: String?
    let tailnetName: String?
    let address: String?
    let brokerHost: String?
    let socket: String?
}

struct Machine: Identifiable, Hashable {
    let id: String
    var name: String
    var os: String
    var httpBase: URL
    var wsBase: URL
    var isHub: Bool = false

    /// Map a hub's `/mesh/peers` entry the way the macOS client does: https
    /// peers are addressed by their MagicDNS name (TLS SNI), http peers by IP.
    static func from(peer p: MeshPeer) -> Machine? {
        guard let host = p.host, !host.isEmpty,
              let scheme = p.scheme, scheme == "http" || scheme == "https" else { return nil }
        let urlHost = host.contains(":") ? "[\(host)]" : host
        guard let http = URL(string: "\(scheme)://\(urlHost):\(brokerPort)"),
              let ws = URL(string: "\(scheme == "https" ? "wss" : "ws")://\(urlHost):\(brokerPort)") else { return nil }
        let id = (p.tailnetName?.isEmpty == false ? p.tailnetName! : host).lowercased()
        let name = (p.name?.isEmpty == false ? p.name! : host)
        return Machine(id: id, name: name, os: p.os ?? "", httpBase: http, wsBase: ws)
    }
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    let name: String
    let windows: Int?
    let attached: Bool?
    let activity: Int64?
    let path: String?
    let state: String?
    let agent: Bool
    let hidden: Bool
    let sessionID: String?

    var id: String { sessionID ?? name }
    /// The stable WebSocket handle (`$N` survives renames), else the name.
    var handle: String { sessionID?.isEmpty == false ? sessionID! : name }

    enum CodingKeys: String, CodingKey {
        case name, windows, attached, activity, path, state, agent, hidden
        case sessionID = "id"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        windows = try c.decodeIfPresent(Int.self, forKey: .windows)
        attached = try c.decodeIfPresent(Bool.self, forKey: .attached)
        activity = try c.decodeIfPresent(Int64.self, forKey: .activity)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        // A broker that predates the field is treated as background (fail closed).
        agent = try c.decodeIfPresent(Bool.self, forKey: .agent) ?? true
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
    }

    init(name: String, state: String? = nil, agent: Bool = false, hidden: Bool = false,
         sessionID: String? = nil, path: String? = nil, activity: Int64? = nil) {
        self.name = name; self.state = state; self.agent = agent; self.hidden = hidden
        self.sessionID = sessionID; self.path = path; self.activity = activity
        windows = nil; attached = nil
    }

    var isForeground: Bool { !agent && !hidden }
}

/// The Mac's Command Center publishes per-broker summaries at `/ccstatus`.
struct CommandCenterItem: Decodable, Hashable {
    let session: String
    let label: String?
    let summary: String?
    let lookAtThis: String?
    let updatedAt: Double?
}

enum AttentionSection: Int, CaseIterable, Identifiable {
    case needsYou, working, idle
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .idle: return "Done & idle"
        }
    }

    /// Same mapping as the Android Command Center: the model's label wins, the
    /// broker's deterministic state is the fallback.
    static func of(label: String?, state: String?) -> AttentionSection {
        switch label {
        case "needs-decision", "stuck": return .needsYou
        case "working", "drifting", "no-progress": return .working
        case "milestone", "look", "idle": return .idle
        default:
            switch state {
            case "waiting": return .needsYou
            case "working": return .working
            default: return .idle
            }
        }
    }
}

// MARK: HTTP

enum BrokerHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func get<T: Decodable>(_ base: URL, _ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        let (data, response) = try await session.data(from: url(base, path, query))
        try check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func post(_ base: URL, _ path: String, query: [URLQueryItem], body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: url(base, path, query))
        req.httpMethod = "POST"
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        try check(response, data)
        return data
    }

    static func url(_ base: URL, _ path: String, _ query: [URLQueryItem]) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw BrokerError.http(message ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }
}

enum BrokerError: LocalizedError {
    case http(String)
    case notABroker
    var errorDescription: String? {
        switch self {
        case .http(let m): return m
        case .notABroker: return "That address answered, but it is not an Argus broker."
        }
    }
}
