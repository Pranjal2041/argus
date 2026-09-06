import Foundation
import Darwin

public enum ArgusLocalSocket {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".argus/run/cli.sock").path
    }
    public static func address(_ path: String) throws -> sockaddr_un {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path), path.hasPrefix("/"), !path.contains("\0") else {
            throw ArgusFailure("invalid_socket_path", "Unix socket path must be absolute and fit within 103 UTF-8 bytes.")
        }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes + Array(repeating: 0, count: $0.count - bytes.count)) }
        return a
    }
    public static func verifyDirectory(_ path: String) throws {
        var s = stat()
        guard lstat(path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR,
              s.st_uid == geteuid(), s.st_mode & 0o077 == 0 else {
            throw ArgusFailure("unsafe_socket_directory", "The CLI socket directory must be owned by this user, not a symlink, and mode 0700: \(path)")
        }
    }
    public static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            throw ArgusFailure("unauthorized_peer", "Argus local control accepts only the same OS user.")
        }
    }
    public static func configure(_ fd: Int32, timeout: Int = 10) {
        // Darwin accepts inherit the listener's nonblocking flag. Client I/O
        // runs off the main actor and must use the bounded blocking timeouts.
        _ = fcntl(fd, F_SETFL, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    public static func readLine(_ fd: Int32, limit: Int, deadlineSeconds: TimeInterval = 35) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        // Deadline is absolute: a slow client cannot hold a worker by trickling bytes.
        let deadline = ProcessInfo.processInfo.systemUptime + deadlineSeconds
        while data.count <= limit && ProcessInfo.processInfo.systemUptime < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ArgusFailure("connection_lost", "Argus did not finish the response. The action may have been accepted; retry mutations with the same --request-id.") }
            data.append(contentsOf: buffer.prefix(n))
            if let end = data.firstIndex(of: 10) {
                guard data.count == end + 1, end <= limit else { throw ArgusFailure("invalid_frame", "Only one bounded JSON message is accepted per connection.") }
                return Data(data.prefix(end))
            }
        }
        throw ArgusFailure("message_too_large", "Local control message exceeded its size or time limit.")
    }
    public static func writeLine(_ fd: Int32, data: Data, limit: Int) throws {
        guard data.count <= limit else { throw ArgusFailure("response_too_large", "Response too large; request a smaller page.") }
        var bytes = data; bytes.append(10)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ArgusFailure("connection_lost", "Could not write local control message.") }
                offset += n
            }
        }
    }
    public static func call(_ request: ArgusRequest, path: String = defaultPath) throws -> ArgusResponse {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: dir) { throw notRunning }
        try verifyDirectory(dir)
        var s = stat()
        guard lstat(path, &s) == 0 else { throw notRunning }
        guard s.st_uid == geteuid(), s.st_mode & S_IFMT == S_IFSOCK, s.st_mode & 0o077 == 0 else {
            throw ArgusFailure("unsafe_socket", "Refusing a socket with unexpected ownership, type, or permissions.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ArgusFailure("socket_error", "Could not create local control socket.") }
        defer { close(fd) }
        configure(fd, timeout: request.method == "events.poll" ? 35 : 15)
        var a = try address(path)
        let connected = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw notRunning }
        try verifyPeer(fd)
        try writeLine(fd, data: ArgusWire.encoder().encode(request), limit: ArgusWire.maxRequestBytes)
        let response = try JSONDecoder().decode(ArgusResponse.self, from: readLine(fd, limit: ArgusWire.maxResponseBytes))
        guard response.version == ArgusWire.version, response.id == request.id else {
            throw ArgusFailure("protocol_mismatch", "CLI/app protocol mismatch. Use the CLI bundled with this Argus app.")
        }
        return response
    }
    public static var notRunning: ArgusFailure {
        ArgusFailure("app_not_running", "Argus local control is unavailable. Open Argus or explicitly run: argus app launch. No app was launched automatically.")
    }
}

/// Bounded I/O outside the main actor. An idle/trickling client cannot monopolize
/// app actions. Long polls are async tasks, never blocked threads or fleet polls.
public final class ArgusSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ArgusRequest) async -> ArgusResponse
    private let queue = DispatchQueue(label: "argus.cli.accept")
    private let io = DispatchQueue(label: "argus.cli.io", attributes: .concurrent)
    private let lock = NSLock()
    private var clients: Set<Int32> = []
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var path: String?
    public init() {}
    public func start(path: String = ArgusLocalSocket.defaultPath, handler: @escaping Handler) throws {
        guard source == nil else { return }
        var a = try ArgusLocalSocket.address(path)
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ArgusLocalSocket.verifyDirectory(dir)
        let lf = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lf >= 0 else { throw ArgusFailure("socket_error", "Cannot open the local control lock.") }
        guard flock(lf, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(lf)
            throw ArgusFailure(code == EWOULDBLOCK ? "already_running" : "socket_lock_failed", "Cannot acquire local control lock (errno \(code)). The existing socket was left untouched.")
        }
        var success = false
        defer { if !success { close(lf) } }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == geteuid(), existing.st_mode & S_IFMT == S_IFSOCK else {
                throw ArgusFailure("unsafe_socket", "Refusing to replace a non-socket or another user's socket.")
            }
            _ = unlink(path) // Only after acquiring the singleton lock.
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ArgusFailure("socket_error", "Could not create local listener.") }
        defer { if !success { close(fd); unlink(path) } }
        ArgusLocalSocket.configure(fd)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let bound = withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            throw ArgusFailure("socket_error", "Could not bind the private local control socket: \(String(cString: strerror(errno)))")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while let self {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                self.lock.lock()
                let allowed = self.clients.count < 32
                if allowed { self.clients.insert(client) }
                self.lock.unlock()
                guard allowed else { close(client); continue }
                ArgusLocalSocket.configure(client, timeout: 2)
                self.io.async { [weak self] in
                    guard let self else { close(client); return }
                    do {
                        try ArgusLocalSocket.verifyPeer(client)
                        let bytes = try ArgusLocalSocket.readLine(client, limit: ArgusWire.maxRequestBytes, deadlineSeconds: 2)
                        let request = try JSONDecoder().decode(ArgusRequest.self, from: bytes)
                        Task {
                            let response = await handler(request)
                            self.io.async {
                                defer { self.finish(client) }
                                do {
                                    try ArgusLocalSocket.writeLine(client, data: ArgusWire.encoder().encode(response), limit: ArgusWire.maxResponseBytes)
                                } catch {
                                    let failure = ArgusResponse(id: request.id, error: (error as? ArgusFailure) ?? ArgusFailure("encoding_error", "Could not encode the response."))
                                    if let data = try? ArgusWire.encoder().encode(failure) { try? ArgusLocalSocket.writeLine(client, data: data, limit: ArgusWire.maxResponseBytes) }
                                }
                            }
                        }
                    } catch { self.finish(client) }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source; self.lockFD = lf; self.path = path
        success = true; source.resume()
    }
    private func finish(_ fd: Int32) {
        lock.lock(); clients.remove(fd); close(fd); lock.unlock()
    }
    public func stop() {
        source?.cancel(); source = nil
        lock.lock(); for fd in clients { shutdown(fd, SHUT_RDWR) }; lock.unlock()
        if let path { unlink(path) }; path = nil
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }
    deinit { stop() }
}
