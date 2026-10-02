import Foundation

/// Credentials and deployment routing come from this connection's private CLI
/// profile. They are never copied into configuration, snapshots, or argv.
@available(macOS 14.0, *)
struct DevinAPICredentials: Sendable {
    var apiKey: String
    var baseURL: URL

    static func load(_ profile: AccountProfile) throws -> Self {
        let url = profile.root.appendingPathComponent("data/devin/credentials.toml")
        guard url.resolvingSymlinksInPath().path.hasPrefix(profile.root.resolvingSymlinksInPath().path + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
              let data = try? Data(contentsOf: url), data.count <= 65_536,
              let text = String(data: data, encoding: .utf8) else {
            throw IntegrationError.authentication("Could not read this Devin account's saved login. Sign in again in Connections.")
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> Self {
        // The CLI writes a flat TOML record. Accept its basic/literal strings,
        // reject duplicate selected keys, and never interpret it as shell code.
        let wanted = Set(["windsurf_api_key", "devin_api_url"])
        let pattern = #"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:[^"\\]|\\.)*"|'[^']*')\s*(?:#.*)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            // Selected credentials must be at the root, never in an unrelated table.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            let key = String(line[keyRange])
            guard wanted.contains(key) else { continue }
            guard values[key] == nil else { throw invalidLogin }
            let quoted = String(line[valueRange])
            if quoted.hasPrefix("'") { values[key] = String(quoted.dropFirst().dropLast()) }
            else {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)) else { throw invalidLogin }
                values[key] = value
            }
        }
        guard let key = values["windsurf_api_key"], !key.isEmpty, key.utf8.count <= 8192,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let rawURL = values["devin_api_url"], let url = URL(string: rawURL),
              url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw invalidLogin }
        return Self(apiKey: key, baseURL: url)
    }

    private static var invalidLogin: IntegrationError {
        .authentication("This Devin account's saved login or API address could not be read. Sign in again in Connections.")
    }
}

@available(macOS 14.0, *)
enum DevinConsumption {
    static func normalize(_ root: JSONValue, account: DevinAccount, configuration: SourceConfiguration, now: Date) throws -> UsageSource {
        try configuration.validateAccountIdentity(account.email)
        guard let cycles = root["consumption"].array else {
            throw IntegrationError.invalidResponse("Devin did not return readable consumption periods.")
        }
        let current = cycles.filter { cycle in
            guard let start = cycle["start"].date, let end = cycle["end"].date else { return false }
            return start <= now && now < end
        }
        guard current.count == 1, let cycle = current.first,
              let start = cycle["start"].date, let end = cycle["end"].date,
              let used = cycle["acus_consumed"].double, used.isFinite, used >= 0 else {
            throw IntegrationError.unavailable("Devin did not report an ACU total for the current consumption period.")
        }
        let period = ConsumptionPeriod(start: start, end: end,
            timeZoneOffsetSeconds: offset(cycle["start"].string ?? ""))
        return UsageSource(id: configuration.id, integration: .devin, account: configuration.label, observedAt: now,
            payload: .consumption(ConsumptionUsage(used: used, unit: "ACUs", period: period, plan: account.plan)),
            origin: .live, accountIdentity: account.email)
    }

    private static func offset(_ timestamp: String) -> Int {
        let parts = DevinOutput.captures(#"([+-])(\d{2}):(\d{2})$"#, timestamp)
        guard parts.count == 3, let hours = Int(parts[1]), let minutes = Int(parts[2]) else { return 0 }
        return (hours * 3600 + minutes * 60) * (parts[0] == "-" ? -1 : 1)
    }
}
