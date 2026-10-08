import Foundation
import Darwin

/// Cross-process append/ack boundary shared by foreground capture and the
/// background inbox consumer. Acknowledgment means bytes are on disk, not merely
/// queued on a process-local DispatchQueue.
enum JournalFileStore {
    static func append(_ lines: [Data], to url: URL, deduplicateIDs: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        var seen = Set<String>()
        if deduplicateIDs {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.seek(toOffset: 0)
            let existing = try handle.readToEnd() ?? Data()
            for line in existing.split(separator: 0x0a) {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let id = object["id"] as? String { seen.insert(id) }
            }
        }
        // A process can die halfway through its final write. Isolate that
        // fragment so the next acknowledged event is still a complete JSONL
        // record; retain the fragment for recovery instead of joining onto it.
        let size = lseek(fd, 0, SEEK_END)
        if size > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, size - 1) == 1 else { throw POSIXError(.EIO) }
            if last != 0x0a {
                var newline: UInt8 = 0x0a
                guard Darwin.write(fd, &newline, 1) == 1 else { throw POSIXError(.EIO) }
            }
        }
        for data in lines {
            if deduplicateIDs, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String {
                guard seen.insert(id).inserted else { continue }
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw POSIXError(.EIO) }; offset += written
                }
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }

    static func ingest(_ text: String, directory: URL) throws {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        var grouped: [String: [Data]] = [:]
        for line in text.split(separator: "\n") {
            let data = Data(line.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["kind"] is String,
                  let ts = object["ts"] as? String, let date = fractional.date(from: ts) ?? plain.date(from: ts) else {
                throw CocoaError(.coderReadCorrupt)
            }
            grouped[day.string(from: date) + ".jsonl", default: []].append(data + Data([0x0a]))
        }
        for (name, lines) in grouped { try append(lines, to: directory.appendingPathComponent(name), deduplicateIDs: true) }
    }
}
