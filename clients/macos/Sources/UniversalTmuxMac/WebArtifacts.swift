import Foundation

struct WebArtifactRecipe: Codable, Identifiable, Hashable, Sendable {
    let schemaVersion: Int
    let id: String
    let name: String
    let machineName: String
    let machineHost: String
    let sessionName: String
    let stableSessionID: String?
    let sessionLineageID: String?
    let workingDirectory: String
    let command: String
    let url: String
    var portMode: String? = nil
    var port: Int? = nil
    let createdAt: Date
    let updatedAt: Date
}

struct WebArtifactItem: Identifiable, Hashable, Sendable {
    let recipe: WebArtifactRecipe
    let machineID: String
    let machineHTTPBase: String
    let reachable: Bool
    var id: String { recipe.id }
}

enum WebArtifactLaunchState: Equatable, Sendable {
    case saved
    case starting
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .saved: return "Saved"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }
}

struct WebArtifactLaunchTarget: Sendable {
    let scheme: String
    let port: Int
    let path: String
}

private struct WebArtifactsResponse: Decodable, Sendable {
    let artifacts: [WebArtifactRecipe]
}

private struct WebArtifactStatusResponse: Decodable, Sendable {
    let id: String
    let state: String
    let url: String
    let message: String?
}

private struct WebArtifactErrorResponse: Decodable {
    let error: String
}

private struct CachedWebArtifact: Codable, Sendable {
    let recipe: WebArtifactRecipe
    let machineID: String
    let machineHTTPBase: String
}

private struct WebArtifactFetchResult: Sendable {
    let machineID: String
    let machineName: String
    let machineHost: String
    let httpBase: String
    let recipes: [WebArtifactRecipe]?
}

/// Aggregates each broker's durable recipes into one local, offline-tolerant
/// library. The originating broker remains authoritative; the Mac cache keeps
/// cards discoverable while a machine is asleep or temporarily unreachable.
@MainActor
final class WebArtifactStore: ObservableObject {
    @Published private(set) var items: [WebArtifactItem] = []
    @Published private(set) var launchStates: [String: WebArtifactLaunchState] = [:]
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Argus/web-artifacts-cache.json")
        loadCache()
    }

    func refresh(machines: [Machine]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let descriptors = machines.map {
            ($0.id, $0.name, $0.host, $0.httpBase)
        }
        var results: [WebArtifactFetchResult] = []
        await withTaskGroup(of: WebArtifactFetchResult.self) { group in
            for descriptor in descriptors {
                group.addTask {
                    await Self.fetch(
                        machineID: descriptor.0,
                        machineName: descriptor.1,
                        machineHost: descriptor.2,
                        httpBase: descriptor.3
                    )
                }
            }
            for await result in group { results.append(result) }
        }

        var merged = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let successfulMachineIDs = Set(results.compactMap { $0.recipes == nil ? nil : $0.machineID })
        let currentByID = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })

        // A successful owner response is authoritative for deletion. Offline
        // machines retain their mirrored cards until they return.
        for (id, item) in merged where successfulMachineIDs.contains(item.machineID) {
            let ownerStillReturned = results.contains { result in
                result.recipes?.contains(where: { $0.id == id }) == true
            }
            if !ownerStillReturned { merged.removeValue(forKey: id) }
        }

        var fetchedRecipes: [String: WebArtifactRecipe] = [:]
        var sourceMachineIDs: [String: Set<String>] = [:]
        for result in results {
            for recipe in result.recipes ?? [] {
                sourceMachineIDs[recipe.id, default: []].insert(result.machineID)
                if let existing = fetchedRecipes[recipe.id], existing.updatedAt >= recipe.updatedAt { continue }
                fetchedRecipes[recipe.id] = recipe
            }
        }
        for recipe in fetchedRecipes.values {
            if let owner = Self.ownerMachine(
                for: recipe,
                sourceMachineIDs: sourceMachineIDs[recipe.id] ?? [],
                machines: machines
            ) {
                merged[recipe.id] = WebArtifactItem(
                    recipe: recipe,
                    machineID: owner.id,
                    machineHTTPBase: owner.httpBase,
                    reachable: true
                )
            } else if let stale = merged[recipe.id] {
                merged[recipe.id] = WebArtifactItem(
                    recipe: recipe,
                    machineID: stale.machineID,
                    machineHTTPBase: stale.machineHTTPBase,
                    reachable: currentByID[stale.machineID] != nil
                )
            } else {
                merged[recipe.id] = WebArtifactItem(
                    recipe: recipe,
                    machineID: "",
                    machineHTTPBase: "",
                    reachable: false
                )
            }
        }
        for (id, item) in merged where fetchedRecipes[id] == nil {
            merged[id] = WebArtifactItem(
                recipe: item.recipe,
                machineID: item.machineID,
                machineHTTPBase: currentByID[item.machineID]?.httpBase ?? item.machineHTTPBase,
                reachable: currentByID[item.machineID] != nil
            )
        }

        items = merged.values.sorted {
            if $0.recipe.updatedAt != $1.recipe.updatedAt { return $0.recipe.updatedAt > $1.recipe.updatedAt }
            return $0.recipe.name.localizedCaseInsensitiveCompare($1.recipe.name) == .orderedAscending
        }
        saveCache()
    }

    /// Resolve the broker that is allowed to execute a recipe. The recorded
    /// hostname is authoritative when it matches a live machine. A recipe seen
    /// from exactly one broker may safely fall back to that source; this covers
    /// the local UI alias (`this mac`) without allowing a recipe mirrored by a
    /// Babel shared store to jump to an arbitrary sibling node.
    nonisolated static func ownerMachine(
        for recipe: WebArtifactRecipe,
        sourceMachineIDs: Set<String>,
        machines: [Machine]
    ) -> Machine? {
        if let exact = machines.first(where: { machine($0, owns: recipe) }) {
            return exact
        }
        guard sourceMachineIDs.count == 1, let sourceID = sourceMachineIDs.first else {
            return nil
        }
        return machines.first { $0.id == sourceID }
    }

    func matching(query: String) -> [WebArtifactItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            [item.recipe.name, item.recipe.sessionName, item.recipe.machineName,
             item.recipe.workingDirectory, item.recipe.url]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    func state(for item: WebArtifactItem) -> WebArtifactLaunchState {
        launchStates[item.id] ?? .saved
    }

    func start(_ item: WebArtifactItem) async -> WebArtifactLaunchTarget? {
        guard item.reachable, !item.machineHTTPBase.isEmpty else {
            errorMessage = "\(item.recipe.machineName) is offline. The recipe is safe, but it cannot run until that machine reconnects."
            return nil
        }
        launchStates[item.id] = .starting
        do {
            let initial = try await command(item: item, path: "/web-artifacts/start", method: "POST")
            if initial.state == "ready" {
                guard let target = Self.launchTarget(from: initial.url) else {
                    throw Self.invalidLaunchURL(initial.url)
                }
                launchStates[item.id] = .ready
                return target
            }
            let deadline = Date().addingTimeInterval(62)
            while Date() < deadline {
                try await Task.sleep(for: .milliseconds(450))
                let status = try await command(item: item, path: "/web-artifacts/status", method: "GET")
                switch status.state {
                case "ready":
                    guard let target = Self.launchTarget(from: status.url) else {
                        throw Self.invalidLaunchURL(status.url)
                    }
                    launchStates[item.id] = .ready
                    return target
                case "failed":
                    let message = status.message ?? "The web artifact did not start."
                    launchStates[item.id] = .failed(message)
                    errorMessage = message
                    return nil
                default:
                    continue
                }
            }
            let message = "The web artifact did not become reachable within 60 seconds."
            launchStates[item.id] = .failed(message)
            errorMessage = message
        } catch {
            launchStates[item.id] = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
        return nil
    }

    func stop(_ item: WebArtifactItem) async {
        guard item.reachable else { return }
        do {
            _ = try await command(item: item, path: "/web-artifacts/stop", method: "POST")
            launchStates[item.id] = .saved
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: WebArtifactItem) async {
        guard item.reachable else {
            errorMessage = "Reconnect \(item.recipe.machineName) before deleting this recipe."
            return
        }
        do {
            var components = URLComponents(string: item.machineHTTPBase + "/web-artifacts")!
            components.queryItems = [.init(name: "id", value: item.id)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 10
            let (data, response) = try await brokerSession.data(for: request)
            try Self.requireSuccess(data: data, response: response)
            items.removeAll { $0.id == item.id }
            launchStates[item.id] = nil
            saveCache()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func command(item: WebArtifactItem, path: String, method: String) async throws -> WebArtifactStatusResponse {
        var components = URLComponents(string: item.machineHTTPBase + path)!
        components.queryItems = [.init(name: "id", value: item.id)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 12
        let (data, response) = try await brokerSession.data(for: request)
        try Self.requireSuccess(data: data, response: response)
        return try JSONDecoder.argusWebArtifacts.decode(WebArtifactStatusResponse.self, from: data)
    }

    nonisolated private static func fetch(
        machineID: String,
        machineName: String,
        machineHost: String,
        httpBase: String
    ) async -> WebArtifactFetchResult {
        guard let url = URL(string: httpBase + "/web-artifacts") else {
            return .init(machineID: machineID, machineName: machineName, machineHost: machineHost,
                         httpBase: httpBase, recipes: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try requireSuccess(data: data, response: response)
            let decoded = try JSONDecoder.argusWebArtifacts.decode(WebArtifactsResponse.self, from: data)
            return .init(machineID: machineID, machineName: machineName, machineHost: machineHost,
                         httpBase: httpBase, recipes: decoded.artifacts)
        } catch {
            return .init(machineID: machineID, machineName: machineName, machineHost: machineHost,
                         httpBase: httpBase, recipes: nil)
        }
    }

    nonisolated private static func requireSuccess(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(WebArtifactErrorResponse.self, from: data).error)
                ?? "The broker rejected the web artifact request."
            throw NSError(domain: "Argus.WebArtifacts", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    nonisolated private static func machine(_ machine: Machine, owns recipe: WebArtifactRecipe) -> Bool {
        let aliases = [machine.name, machine.host, machine.id,
                       URLComponents(string: machine.httpBase)?.host ?? ""]
            .map(normalizedMachine)
        return aliases.contains(normalizedMachine(recipe.machineName)) ||
            aliases.contains(normalizedMachine(recipe.machineHost))
    }

    nonisolated private static func normalizedMachine(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("ut-") { value.removeFirst(3) }
        return value.split(separator: ".", maxSplits: 1).first.map(String.init) ?? value
    }

    nonisolated private static func launchTarget(from raw: String) -> WebArtifactLaunchTarget? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty { path += "?" + query }
        return .init(scheme: scheme, port: port, path: path)
    }

    nonisolated private static func invalidLaunchURL(_ raw: String) -> NSError {
        NSError(
            domain: "Argus.WebArtifacts",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The broker returned an invalid launch URL: \(raw)"]
        )
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder.argusWebArtifacts.decode([CachedWebArtifact].self, from: data) else { return }
        items = cached.map {
            WebArtifactItem(recipe: $0.recipe, machineID: $0.machineID,
                            machineHTTPBase: $0.machineHTTPBase, reachable: false)
        }.sorted { $0.recipe.updatedAt > $1.recipe.updatedAt }
    }

    private func saveCache() {
        let cached = items.map {
            CachedWebArtifact(recipe: $0.recipe, machineID: $0.machineID,
                              machineHTTPBase: $0.machineHTTPBase)
        }
        guard let data = try? JSONEncoder.argusWebArtifacts.encode(cached) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static var argusWebArtifacts: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var argusWebArtifacts: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
