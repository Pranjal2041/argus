import Foundation

/// A portable reference is not a live connection. In particular it cannot carry
/// a loopback forward allocated by another device or a browser credential.
public enum WorkspaceLocator {
    public static func website(_ raw: String) throws -> ArgusJSON {
        guard let components = URLComponents(string: raw),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()),
              components.user == nil, components.password == nil,
              !(components.queryItems ?? []).contains(where: { sensitive($0.name) }),
              components.fragment == nil else {
            throw ArgusFailure("nonportable_url", "Use a website URL without login parameters, or save this as a host service.")
        }
        return .object(["kind": .string("website"), "url": .string(raw)])
    }

    public static func service(brokerID: String, port: Int, path: String = "/", scheme: String = "http") throws -> ArgusJSON {
        guard !brokerID.isEmpty, (1...65535).contains(port), ["http", "https"].contains(scheme),
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\n"),
              let parts = URLComponents(string: "http://placeholder" + path),
              parts.fragment == nil, !(parts.queryItems ?? []).contains(where: { sensitive($0.name) }) else {
            throw ArgusFailure("invalid_service", "A service needs a stable host, port, and path without login parameters.")
        }
        return .object(["kind": .string("service"), "brokerID": .string(brokerID), "port": .number(Double(port)), "path": .string(path), "scheme": .string(scheme)])
    }

    private static func sensitive(_ key: String) -> Bool {
        let key = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["code", "auth", "authorization", "session", "sessionid", "key", "api_key"].contains(key)
            || ["token", "password", "secret", "credential"].contains(where: key.contains)
    }
}
