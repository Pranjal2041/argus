import Foundation

/// A self-contained sample fleet for trying Argus without a tailnet (and for
/// App Review). Requests to hosts under `.demo.invalid` (a reserved,
/// never-resolving domain) are answered in-process by `DemoURLProtocol`, so
/// every screen runs its real code against a realistic fleet.
enum DemoFleet {
    static let suffix = ".demo.invalid"
    static let hubHost = "studio-mac" + suffix

    static func isDemo(_ url: URL) -> Bool { url.host?.hasSuffix(suffix) == true }
    static func isDemo(_ m: Machine) -> Bool { isDemo(m.httpBase) }

    struct Host { let host: String; let name: String; let os: String; let home: String }
    static let hosts: [Host] = [
        Host(host: hubHost, name: "studio-mac", os: "darwin", home: "/Users/demo"),
        Host(host: "gpu-node-07" + suffix, name: "gpu-node-07", os: "linux", home: "/home/demo"),
        Host(host: "lab-server" + suffix, name: "lab-server", os: "linux", home: "/home/demo"),
    ]

    struct Session { var name: String; var state: String; var path: String; var label: String; var summary: String; var look: String?; var output: String }

    /// Mutable demo state, shared by the HTTP handler and the demo terminal.
    final class State: @unchecked Sendable {
        static let shared = State()
        private let lock = NSLock()
        private var sessions: [String: [Session]] = [
            "studio-mac": [
                Session(name: "web-redesign", state: "waiting", path: "/Users/demo/web", label: "needs-decision",
                        summary: "Claude finished the new pricing page and is asking whether to also update the mobile breakpoints.",
                        look: "? Update the mobile breakpoints too? (y/n)",
                        output: "⏺ Updated pricing page layout (3 files)\n⏺ All 41 tests pass\n\n? Update the mobile breakpoints too? (y/n) "),
            ],
            "gpu-node-07": [
                Session(name: "train-llama-ft", state: "working", path: "/home/demo/ft", label: "working",
                        summary: "Fine-tuning run at step 4,200 of 10,000; loss is falling steadily (1.92 → 1.41).",
                        look: "step 4200 | loss 1.41 | 3.1 it/s",
                        output: "wandb: 🚀 View run brave-falcon-12 at: https://wandb.ai/demo/ft/runs/bf12\nstep 4100 | loss 1.44 | 3.1 it/s\nstep 4200 | loss 1.41 | 3.1 it/s\n"),
                Session(name: "eval-sweep", state: "idle", path: "/home/demo/eval", label: "milestone",
                        summary: "The evaluation sweep finished: 12 of 12 configs complete, best accuracy 87.4%.",
                        look: nil, output: "✓ 12/12 configs done — best: lr=3e-5, acc=87.4%\n$ "),
            ],
            "lab-server": [
                Session(name: "data-pipeline", state: "waiting", path: "/home/demo/pipeline", label: "stuck",
                        summary: "Codex hit a permission error writing to /data/shards and is waiting for direction.",
                        look: "PermissionError: [Errno 13] /data/shards/part-0007",
                        output: "› Writing shards…\nPermissionError: [Errno 13] Permission denied: '/data/shards/part-0007'\n\nHow should I proceed? "),
            ],
        ]
        private var labDecided = false

        func with<T>(_ body: (inout [String: [Session]]) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&sessions)
        }
        var keyPending: Bool { lock.lock(); defer { lock.unlock() }; return !labDecided }
        func decideKey() { lock.lock(); labDecided = true; lock.unlock() }
    }
}

final class DemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url.map(DemoFleet.isDemo) ?? false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = DemoFleet.hosts.first(where: { $0.host == url.host }) else { return finish(404, "{}") }
        let q = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                           uniquingKeysWith: { a, _ in a })
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let (status, payload) = route(url.path, host: host, q: q, body: body)
        finish(status, payload)
    }

    private func finish(_ status: Int, _ body: String) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": body.hasPrefix("{") || body.hasPrefix("[") ? "application/json" : "text/plain"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ s: InputStream) -> Data {
        s.open(); defer { s.close() }
        var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
        return d
    }

    private static func json(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func route(_ path: String, host h: DemoFleet.Host, q: [String: String], body: Data) -> (Int, String) {
        let state = DemoFleet.State.shared
        let now = Int(Date().timeIntervalSince1970)
        switch path {
        case "/whoami":
            return (200, Self.json(["service": "universal-tmux-broker", "proto": 1, "name": h.name, "host": h.name, "socket": "ut", "os": h.os]))
        case "/mesh/peers":
            let peers = DemoFleet.hosts.filter { $0.host != h.host }.map {
                ["name": $0.name, "host": $0.host, "scheme": "http", "os": $0.os, "brokerHost": $0.name, "socket": "ut"]
            }
            return (200, Self.json(["peers": peers]))
        case "/sessions":
            let list = state.with { $0[h.name] ?? [] }.enumerated().map { i, s in
                ["name": s.name, "windows": 1, "attached": false, "activity": now - 60 * (i + 2), "path": s.path,
                 "state": s.state, "agent": false, "hidden": false, "id": "$\(i)"] as [String: Any]
            }
            return (200, Self.json(["sessions": list]))
        case "/ccstatus":
            let items = state.with { $0[h.name] ?? [] }.map { s in
                ["session": s.name, "label": s.label, "summary": s.summary, "lookAtThis": s.look as Any, "updatedAt": Double(now - 90)] as [String: Any]
            }
            return (200, Self.json(["items": items]))
        case "/control":
            let name = q["session"] ?? ""
            state.with { all in
                var list = all[h.name] ?? []
                switch q["action"] {
                case "create": list.append(.init(name: name, state: "idle", path: q["dir"].flatMap { $0.isEmpty ? nil : $0 } ?? h.home,
                                                  label: "idle", summary: "A new shell is ready.", look: nil, output: "$ "))
                case "kill": list.removeAll { $0.name == name }
                case "rename": if let i = list.firstIndex(where: { $0.name == name }) { list[i].name = q["to"] ?? name }
                default: break
                }
                all[h.name] = list
            }
            return (200, #"{"ok":true}"#)
        case "/send":
            let text = String(decoding: body, as: UTF8.self)
            state.with { all in
                guard var list = all[h.name], let i = list.firstIndex(where: { $0.name == q["session"] }) else { return }
                list[i].output += text + "\n⏺ Got it — continuing.\n"
                list[i].state = "working"; list[i].label = "working"
                list[i].summary = "Working on your reply: “\(text)”."
                all[h.name] = list
            }
            return (200, #"{"ok":true}"#)
        case "/recent":
            return (200, state.with { $0[h.name]?.first { $0.name == q["session"] }?.output } ?? "")
        case "/render-source":
            return (200, Self.json(["source": "## Summary\n\nThe pricing page now uses a **three-tier** layout.\n\n| Plan | Price |\n|---|---|\n| Starter | $0 |\n| Pro | $12 |\n| Team | $40 |\n\nAll tests pass: $41/41$.",
                                    "format": "markdown", "origin": "claude-transcript", "confidence": 0.9]))
        case "/hidden", "/ccoverride", "/journal/append", "/fs/write", "/fs/mkdir", "/fs/rename", "/fs/delete":
            return (200, #"{"ok":true}"#)
        case "/fs/home":
            return (200, Self.json(["home": h.home, "roots": ["/"], "sep": "/"]))
        case "/fs/list":
            let dir = (q["path"] ?? h.home).replacingOccurrences(of: "~", with: h.home)
            let entries: [[String: Any]] = [
                ["name": "README.md", "path": dir + "/README.md", "isDir": false, "size": 412, "mtime": now - 3600],
                ["name": "notes", "path": dir + "/notes", "isDir": true, "size": 0, "mtime": now - 7200],
                ["name": "train.py", "path": dir + "/train.py", "isDir": false, "size": 2048, "mtime": now - 600],
            ]
            return (200, Self.json(["path": dir, "entries": entries]))
        case "/fs/stat":
            return (200, Self.json(["path": q["path"] ?? h.home, "name": "", "isDir": true, "exists": true, "size": 0]))
        case "/fs/read":
            if q["path"]?.hasSuffix(".md") == true { return (200, "# Demo project\n\nThis is a **sample** file on \(h.name).\n\n- Browse, preview and edit files on any machine\n- Search names and contents\n") }
            return (200, "import torch\n\n# Demo training script on \(h.name)\nfor step in range(10_000):\n    loss = train_step()\n")
        case "/fs/find":
            return (200, Self.json(["root": q["path"] ?? h.home, "files": [["name": "train.py", "path": h.home + "/train.py", "isDir": false]], "truncated": false]))
        case "/fs/grep":
            return (200, Self.json(["root": q["path"] ?? h.home, "matches": [["path": h.home + "/train.py", "line": 4, "text": "for step in range(10_000):"]], "truncated": false]))
        case "/lab/notes":
            return (200, Self.json(["store": "demo-" + h.name, "notes": []]))
        case "/lab/sets":
            return (200, #"{"sets":[]}"#)
        case "/lab/keys":
            guard h.name == "gpu-node-07", state.keyPending else { return (200, #"{"keys":[]}"#) }
            let created = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -300))
            return (200, Self.json(["keys": [["key": "a1b2c3d4e5f60718293a4b5c6d7e8f90", "project": "llama-finetune", "machine": "gpu-node-07",
                                              "cwd": "/home/demo/ft", "session": "train-llama-ft", "status": "pending", "created": created]]]))
        case "/lab/decide":
            state.decideKey()
            return (200, #"{"key":"a1b2c3d4e5f60718293a4b5c6d7e8f90","project":"llama-finetune","machine":"gpu-node-07","cwd":"/home/demo/ft","status":"active","created":"2026-01-01T00:00:00Z"}"#)
        case "/lab/proposals":
            return (200, #"{"proposals":[]}"#)
        case "/lab/mirror":
            return (200, #"{"mirror":[]}"#)
        case "/automation/unattended":
            return (200, Self.json(["enabled": q["enabled"] == "true", "updatedAt": now * 1000]))
        case "/userdata/merge":
            let sent = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["data"] ?? []
            return (200, Self.json(["updatedAt": now * 1000, "data": sent, "mergeVersion": 1]))
        case "/weekly-progress/catalog":
            return (200, Self.json(["version": 1, "generatedAt": ISO8601DateFormatter().string(from: Date()), "projects": [], "generations": []]))
        case "/git/summary":
            return (400, #"{"error":"not a git repository"}"#)
        default:
            return (404, #"{"error":"not available in the demo"}"#)
        }
    }
}

/// The demo terminal: shows a session's recent output and answers a few
/// commands, so typing works without a real machine.
enum DemoShell {
    static func screen(machine: Machine, handle: String) -> String {
        let name = DemoFleet.hosts.first { $0.host == machine.httpBase.host }?.name ?? "demo"
        let out = DemoFleet.State.shared.with { all in
            (all[name] ?? []).enumerated().first { "$\($0.offset)" == handle || $0.element.name == handle }?.element.output
        } ?? "$ "
        return "\u{1b}[2J\u{1b}[H\u{1b}[2m# Demo session on \(name) — try typing `ls` or `help`\u{1b}[0m\r\n" + out.replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func run(_ command: String) -> String {
        switch command.trimmingCharacters(in: .whitespaces) {
        case "": return ""
        case "ls": return "README.md  notes  train.py"
        case "pwd": return "/home/demo"
        case "help": return "Demo shell: ls, pwd, whoami, date, echo …  Connect your Mac in Settings to use real machines."
        case "whoami": return "demo"
        case "date": return Date().formatted(date: .abbreviated, time: .standard)
        case let c where c.hasPrefix("echo "): return String(c.dropFirst(5))
        case let c: return "\(c.split(separator: " ").first ?? ""): not available in the demo"
        }
    }
}
