import Foundation
import Network

private struct WeeklyProgressRemoteProject: Encodable {
    let id: String
    let name: String
    let panelCount: Int
    let workspaceCount: Int
    let updatedAt: Date
}

private struct WeeklyProgressRemoteGeneration: Encodable {
    let id: String
    let projectID: String
    let projectName: String
    let weekStart: String
    let weekEndExclusive: String
    let createdAt: Date
    let updatedAt: Date
    let stage: String
    let state: String
    let auditPasses: Int
    let slideCount: Int
    let hasDeck: Bool
    let hasReport: Bool
    let evidenceEventCount: Int?
    let error: String?
}

private struct WeeklyProgressRemoteOperation: Encodable {
    let generationID: String
    let projectID: String
    let projectName: String
    let weekStart: String
    let stage: String
    let startedAt: Date
}

private struct WeeklyProgressRemoteCatalog: Encodable {
    let version: Int
    let generatedAt: Date
    let projects: [WeeklyProgressRemoteProject]
    let generations: [WeeklyProgressRemoteGeneration]
    let activeOperation: WeeklyProgressRemoteOperation?
}

private struct WeeklyProgressRemoteCommandResponse: Encodable {
    let ok: Bool
    let generation: WeeklyProgressRemoteGeneration
}

private struct WeeklyProgressRemoteCommand: Decodable {
    let projectID: String?
    let weekStart: String?
    let generationID: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case weekStart = "week_start"
        case generationID = "generation_id"
        case requestID = "request_id"
    }
}

struct WeeklyProgressRemoteTestResponse {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/// A loopback-only weekly-progress.v1 provider. The Mac broker supplies mesh
/// reachability; this service owns generation semantics and validates every
/// asset by durable generation UUID rather than accepting filesystem paths.
@MainActor
final class WeeklyProgressRemoteService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var providerPort: UInt16?

    private let api: WeeklyProgressRemoteAPI
    private var listener: WeeklyProgressLoopbackServer?
    private var heartbeat: Timer?

    init(
        coordinator: WeeklyProgressCoordinator,
        store: WeeklyProgressDiskStore = WeeklyProgressDiskStore()
    ) {
        self.api = WeeklyProgressRemoteAPI(coordinator: coordinator, store: store)
    }

    func start() {
        guard listener == nil else { return }
        let api = self.api
        let server = WeeklyProgressLoopbackServer { request in
            await api.handle(request)
        }
        listener = server
        server.start { [weak self] port in
            Task { @MainActor in
                guard let self else { return }
                self.providerPort = port
                self.isRunning = true
                await self.registerProvider()
                self.startHeartbeat()
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.registerProvider() }
        }
    }

    private func registerProvider() async {
        guard let providerPort,
              let url = URL(string: "http://127.0.0.1:8722/weekly-progress/provider") else { return }
        let payload: [String: Any] = [
            "port": Int(providerPort),
            "version": 1,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "provider": "Argus",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Direct protocol seam for deterministic provider tests. Production uses
    /// the loopback listener and reaches the same API actor.
    func processForTesting(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) async -> WeeklyProgressRemoteTestResponse {
        let response = await api.handle(WeeklyProgressHTTPRequest(
            method: method,
            path: path,
            headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }),
            body: body
        ))
        let data: Data
        switch response.body {
        case let .data(value):
            data = value
        case let .file(url, offset, length):
            let handle = try? FileHandle(forReadingFrom: url)
            try? handle?.seek(toOffset: offset)
            data = (try? handle?.read(upToCount: Int(length))) ?? Data()
            try? handle?.close()
        case .empty:
            data = Data()
        }
        return WeeklyProgressRemoteTestResponse(
            status: response.status,
            headers: response.headers,
            body: data
        )
    }
}

/// Request handling and catalog/file discovery never run on AppKit's main
/// actor. Only the tiny provider heartbeat above is UI-process state.
private actor WeeklyProgressRemoteAPI {
    private let coordinator: WeeklyProgressCoordinator
    private let store: WeeklyProgressDiskStore

    init(coordinator: WeeklyProgressCoordinator, store: WeeklyProgressDiskStore) {
        self.coordinator = coordinator
        self.store = store
    }

    func handle(_ request: WeeklyProgressHTTPRequest) async -> WeeklyProgressHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/catalog"), ("HEAD", "/catalog"):
            return await catalogResponse(headOnly: request.method == "HEAD")
        case ("POST", "/generate"):
            return await generate(request)
        case ("POST", "/resume"):
            return await resume(request)
        default:
            if request.method == "GET" || request.method == "HEAD" {
                return await asset(request)
            }
            return .jsonError("not found", status: 404)
        }
    }

    private func catalogResponse(headOnly: Bool) async -> WeeklyProgressHTTPResponse {
        let operation = await coordinator.snapshot().operation
        let projects = store.loadProjects()
        let generations = store.allGenerations(projects: projects)
        let response = WeeklyProgressRemoteCatalog(
            version: 1,
            generatedAt: Date(),
            projects: projects.map {
                WeeklyProgressRemoteProject(
                    id: $0.id.uuidString.lowercased(),
                    name: $0.name,
                    panelCount: $0.panels.count,
                    workspaceCount: $0.workspaceRoots.count,
                    updatedAt: $0.updatedAt
                )
            },
            generations: generations.map { remoteGeneration($0, operation: operation) },
            activeOperation: operation.map {
                WeeklyProgressRemoteOperation(
                    generationID: $0.generationID.uuidString.lowercased(),
                    projectID: $0.projectID.uuidString.lowercased(),
                    projectName: $0.projectName,
                    weekStart: Self.day($0.weekStart),
                    stage: $0.stage.rawValue,
                    startedAt: $0.startedAt
                )
            }
        )
        return .json(response, headOnly: headOnly)
    }

    private func generate(_ request: WeeklyProgressHTTPRequest) async -> WeeklyProgressHTTPResponse {
        do {
            let command = try decodeCommand(request)
            guard let rawProject = command.projectID,
                  let projectID = UUID(uuidString: rawProject),
                  let rawWeek = command.weekStart,
                  let date = Self.dayFormatter.date(from: rawWeek),
                  let requestID = command.requestID else {
                return .jsonError("generate requires project_id, week_start, and request_id", status: 400)
            }
            let generation = try await coordinator.start(
                projectID: projectID,
                week: WeeklyProgressWeek(start: date),
                requestID: requestID
            )
            let operation = await coordinator.snapshot().operation
            return .json(
                WeeklyProgressRemoteCommandResponse(
                    ok: true,
                    generation: remoteGeneration(generation, operation: operation)
                ),
                status: 202
            )
        } catch {
            return commandError(error)
        }
    }

    private func resume(_ request: WeeklyProgressHTTPRequest) async -> WeeklyProgressHTTPResponse {
        do {
            let command = try decodeCommand(request)
            guard let rawGeneration = command.generationID,
                  let generationID = UUID(uuidString: rawGeneration),
                  let requestID = command.requestID else {
                return .jsonError("resume requires generation_id and request_id", status: 400)
            }
            let generation = try await coordinator.resume(
                generationID: generationID,
                requestID: requestID
            )
            let operation = await coordinator.snapshot().operation
            return .json(
                WeeklyProgressRemoteCommandResponse(
                    ok: true,
                    generation: remoteGeneration(generation, operation: operation)
                ),
                status: 202
            )
        } catch {
            return commandError(error)
        }
    }

    private func commandError(_ error: Error) -> WeeklyProgressHTTPResponse {
        let status: Int
        switch error {
        case WeeklyProgressCoordinatorError.projectNotFound,
             WeeklyProgressCoordinatorError.generationNotFound:
            status = 404
        case WeeklyProgressCoordinatorError.busy:
            status = 409
        default:
            status = 400
        }
        return .jsonError(error.localizedDescription, status: status)
    }

    private func decodeCommand(_ request: WeeklyProgressHTTPRequest) throws -> WeeklyProgressRemoteCommand {
        let decoder = JSONDecoder()
        return try decoder.decode(WeeklyProgressRemoteCommand.self, from: request.body)
    }

    private func remoteGeneration(
        _ generation: WeeklyProgressGeneration,
        operation: WeeklyProgressOperationSnapshot?
    ) -> WeeklyProgressRemoteGeneration {
        let manifest = generation.manifest
        let slides = WeeklyProgressSlideCatalog.urls(for: generation)
        let deck = generation.directory.appendingPathComponent("weekly-progress.pptx")
        let report = generation.directory.appendingPathComponent("research-report.md")
        let state: String
        if operation?.generationID == manifest.id {
            state = "active"
        } else if manifest.stage == .complete {
            state = "complete"
        } else if manifest.stage == .failed {
            state = "failed"
        } else {
            state = "interrupted"
        }
        return WeeklyProgressRemoteGeneration(
            id: manifest.id.uuidString.lowercased(),
            projectID: manifest.project.id.uuidString.lowercased(),
            projectName: manifest.project.name,
            weekStart: manifest.week.storageKey,
            weekEndExclusive: Self.day(manifest.week.endExclusive),
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt,
            stage: manifest.stage.rawValue,
            state: state,
            auditPasses: manifest.auditPasses,
            slideCount: slides.count,
            hasDeck: FileManager.default.fileExists(atPath: deck.path),
            hasReport: FileManager.default.fileExists(atPath: report.path),
            evidenceEventCount: manifest.evidence?.eventCount,
            error: manifest.error
        )
    }

    private func asset(_ request: WeeklyProgressHTTPRequest) async -> WeeklyProgressHTTPResponse {
        let pieces = request.path.split(separator: "/").map(String.init)
        guard pieces.count >= 3, pieces[0] == "asset",
              let generationID = UUID(uuidString: pieces[1]),
              let generation = await coordinator.generation(id: generationID) else {
            return .jsonError("asset not found", status: 404)
        }

        let url: URL
        let contentType: String
        var downloadName: String?
        switch pieces[2] {
        case "deck" where pieces.count == 3:
            url = generation.directory.appendingPathComponent("weekly-progress.pptx")
            contentType = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            downloadName = Self.safeFilename(
                "\(generation.manifest.project.name)-week-of-\(generation.manifest.week.storageKey).pptx"
            )
        case "report" where pieces.count == 3:
            url = generation.directory.appendingPathComponent("research-report.md")
            contentType = "text/markdown; charset=utf-8"
        case "slide" where pieces.count == 4:
            guard let number = Int(pieces[3]), number > 0,
                  let slide = WeeklyProgressSlideCatalog.urls(for: generation).first(where: {
                      WeeklyProgressSlideCatalog.slideNumber($0) == number
                  }) else { return .jsonError("slide not found", status: 404) }
            url = slide
            contentType = "image/png"
        default:
            return .jsonError("asset not found", status: 404)
        }
        return WeeklyProgressHTTPResponse.file(
            url,
            contentType: contentType,
            requestHeaders: request.headers,
            headOnly: request.method == "HEAD",
            downloadName: downloadName
        )
    }

    private static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = .current
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()

    private static func safeFilename(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct WeeklyProgressHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> WeeklyProgressHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let rawHeaders = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = rawHeaders.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            headers[String(pieces[0]).lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let rawPath = String(requestLine[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return WeeklyProgressHTTPRequest(
            method: String(requestLine[0]),
            path: path,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}

private enum WeeklyProgressHTTPBody {
    case data(Data)
    case file(URL, offset: UInt64, length: UInt64)
    case empty
}

private struct WeeklyProgressHTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: WeeklyProgressHTTPBody

    static func json<T: Encodable>(_ value: T, status: Int = 200, headOnly: Bool = false) -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data(#"{"error":"serialization failed"}"#.utf8)
        return WeeklyProgressHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json", "Content-Length": "\(data.count)"],
            body: headOnly ? .empty : .data(data)
        )
    }

    static func json(_ value: [String: Any], status: Int = 200) -> Self {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            ?? Data(#"{"error":"serialization failed"}"#.utf8)
        return WeeklyProgressHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json", "Content-Length": "\(data.count)"],
            body: .data(data)
        )
    }

    static func jsonError(_ message: String, status: Int) -> Self {
        json(["error": message], status: status)
    }

    static func file(
        _ url: URL,
        contentType: String,
        requestHeaders: [String: String],
        headOnly: Bool,
        downloadName: String?
    ) -> Self {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let rawSize = values.fileSize, rawSize >= 0 else {
            return .jsonError("asset not found", status: 404)
        }
        let size = UInt64(rawSize)
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let etag = "\"\(rawSize)-\(Int64(modified))\""
        if requestHeaders["if-none-match"] == etag {
            return WeeklyProgressHTTPResponse(status: 304, headers: ["ETag": etag], body: .empty)
        }

        var offset: UInt64 = 0
        var length = size
        var status = 200
        var headers: [String: String] = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Cache-Control": "private, max-age=604800, immutable",
            "ETag": etag,
        ]
        if let range = requestHeaders["range"],
           let parsed = byteRange(range, size: size) {
            offset = parsed.lowerBound
            length = parsed.upperBound - parsed.lowerBound + 1
            status = 206
            headers["Content-Range"] = "bytes \(parsed.lowerBound)-\(parsed.upperBound)/\(size)"
        }
        headers["Content-Length"] = "\(length)"
        if let downloadName {
            headers["Content-Disposition"] = "attachment; filename=\"\(downloadName)\""
        }
        return WeeklyProgressHTTPResponse(
            status: status,
            headers: headers,
            body: headOnly ? .empty : .file(url, offset: offset, length: length)
        )
    }

    private static func byteRange(_ raw: String, size: UInt64) -> ClosedRange<UInt64>? {
        guard size > 0, raw.hasPrefix("bytes="), !raw.contains(",") else { return nil }
        let pieces = raw.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        if pieces[0].isEmpty, let suffix = UInt64(pieces[1]), suffix > 0 {
            let count = min(suffix, size)
            return (size - count)...(size - 1)
        }
        guard let start = UInt64(pieces[0]), start < size else { return nil }
        let requestedEnd = pieces[1].isEmpty ? size - 1 : (UInt64(pieces[1]) ?? size - 1)
        return start...min(requestedEnd, size - 1)
    }
}

private final class WeeklyProgressLoopbackServer {
    typealias Handler = @Sendable (WeeklyProgressHTTPRequest) async -> WeeklyProgressHTTPResponse
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.argus.weekly-progress-provider")
    private var listener: NWListener?

    init(handler: @escaping Handler) { self.handler = handler }

    func start(ready: @escaping (UInt16) -> Void) {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port { ready(port.rawValue) }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch {
            NSLog("Argus weekly progress provider failed to listen: %@", error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > 2 * 1024 * 1024 {
                self.send(.jsonError("request too large", status: 413), on: connection)
                return
            }
            if let request = WeeklyProgressHTTPRequest.parse(accumulated) {
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
            } else if complete || error != nil {
                self.send(.jsonError("incomplete HTTP request", status: 400), on: connection)
            } else {
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    private func send(_ response: WeeklyProgressHTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { connection.cancel(); return }
            switch response.body {
            case let .data(data):
                connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
            case let .file(url, offset, length):
                self.sendFile(url, offset: offset, remaining: length, on: connection)
            case .empty:
                connection.cancel()
            }
        })
    }

    private func sendFile(_ url: URL, offset: UInt64, remaining: UInt64, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { connection.cancel(); return }
        do {
            try handle.seek(toOffset: offset)
            sendChunk(handle, remaining: remaining, on: connection)
        } catch {
            try? handle.close()
            connection.cancel()
        }
    }

    private func sendChunk(_ handle: FileHandle, remaining: UInt64, on connection: NWConnection) {
        if remaining == 0 {
            try? handle.close()
            connection.cancel()
            return
        }
        let count = Int(min(remaining, 256 * 1024))
        guard let data = try? handle.read(upToCount: count), !data.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.sendChunk(handle, remaining: remaining - UInt64(data.count), on: connection)
        })
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 206: return "Partial Content"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
