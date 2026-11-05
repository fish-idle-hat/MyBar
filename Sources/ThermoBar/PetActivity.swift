import Foundation
import SQLite3

struct PetActivity: Equatable {
    var codexWorking = false
    var codexAvailable = false
    var musicPlaying = false
    var fansSpinning = false

    static func fansAreSpinning(_ speeds: [Double?]) -> Bool {
        speeds.contains { $0.map { $0.isFinite && $0 > 0 } ?? false }
    }
}

struct PetSettings: Codable, Equatable {
    var enabled = false
    var codex = true
    var music = true
    var fans = true
    var scale: Double = 1.1
    var x: Double?
    var y: Double?
    static let key = "MyBar.Pet.Settings.v1"

    mutating func sanitize() {
        scale = scale.isFinite ? min(1.6, max(0.75, scale)) : 1.1
        if x?.isFinite == false || y?.isFinite == false { x = nil; y = nil }
    }
}

// An optional, read-only adapter to Codex's local implementation details, not
// an official API. Only lifecycle markers are used. Never save conversation text.
// Bounded indexed discovery + incremental tails: no recursive session scans.
final class PetCodexActivityReader {
    struct Cursor {
        var offset: UInt64 = 0
        var remainder = Data()
        var working = false
        var lastActivity = Date.distantPast

        mutating func consume(_ data: Data, now: Date) {
            remainder.append(data)
            // A tool result may be much larger than the tail budget. Drop it,
            // not the lifecycle marker following its terminating newline.
            while let newline = remainder.firstIndex(of: 10) {
                let line = remainder.prefix(upTo: newline)
                remainder.removeSubrange(...newline)
                guard line.count <= 131_072,
                      let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      value["type"] as? String == "event_msg",
                      let payload = value["payload"] as? [String: Any],
                      let kind = payload["type"] as? String,
                      let stamp = value["timestamp"] as? String,
                      let date = PetCodexActivityReader.parseDate(stamp),
                      date <= now.addingTimeInterval(60) else { continue }
                switch kind {
                case "task_started", "turn_started", "agent_message", "agent_reasoning", "item_completed":
                    working = true; lastActivity = date
                case "token_count":
                    // A delayed usage report must not revive a completed turn.
                    if working || lastActivity == .distantPast { working = true; lastActivity = date }
                case "task_complete", "turn_complete", "turn_aborted", "task_failed":
                    working = false; lastActivity = date
                default: break
                }
            }
            if remainder.count > 131_072 { remainder.removeAll(keepingCapacity: false) }
            if now.timeIntervalSince(lastActivity) > 1_800 { working = false }
        }
    }

    private let root: URL
    private var cursors: [URL: Cursor] = [:]
    private let maximumBytes = 131_072
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.root = root }

    func read(now: Date = Date()) -> (working: Bool, available: Bool) {
        var db: OpaquePointer?
        let path = root.appendingPathComponent("state_5.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; cursors.removeAll(); return (false, false)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 25)
        var statement: OpaquePointer?
        let query = "SELECT rollout_path FROM threads INDEXED BY idx_threads_updated_at WHERE updated_at >= ? ORDER BY updated_at DESC LIMIT 16"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return (false, false) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(now.timeIntervalSince1970 - 86_400))
        var paths: [URL] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                let url = URL(fileURLWithPath: String(cString: text)).standardizedFileURL
                // Treat database paths as untrusted. Only local rollout logs.
                let sessions = root.appendingPathComponent("sessions").standardizedFileURL.path + "/"
                if url.path.hasPrefix(sessions), url.pathExtension == "jsonl",
                   url.resolvingSymlinksInPath().path.hasPrefix(sessions) { paths.append(url) }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { return (false, false) }
        let retained = Set(paths)
        cursors = cursors.filter { retained.contains($0.key) }
        for url in paths {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            var cursor = cursors[url] ?? Cursor()
            if size < cursor.offset { cursor = Cursor() }
            var offset = cursor.offset
            let truncated = size - offset > maximumBytes
            if truncated { offset = size - UInt64(maximumBytes); cursor.remainder.removeAll() }
            do {
                try handle.seek(toOffset: offset)
                var data = try handle.read(upToCount: maximumBytes) ?? Data()
                if truncated, let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
                cursor.consume(data, now: now)
                cursor.offset = size
                cursors[url] = cursor
            } catch { cursors.removeValue(forKey: url) }
        }
        return (cursors.values.contains { $0.working && now.timeIntervalSince($0.lastActivity) <= 1_800 }, paths.isEmpty || !cursors.isEmpty)
    }

    func clear() { cursors.removeAll() }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func parseDate(_ value: String) -> Date? { fractional.date(from: value) ?? plain.date(from: value) }
}
