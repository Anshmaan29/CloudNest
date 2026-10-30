import Foundation
import CSQLite
import Darwin

public struct StorageActivity: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case archiveVerified, folderVerified, restored, recoveryStaged, putBack, removed, scanned, paused, failed }
    public let id: UUID
    public let kind: Kind
    public let title: String
    public let detail: String
    public let jobID: UUID?
    public let bytes: Int64
    public let observedFreeBytes: Int64
    public let timestamp: Date
    public init(kind: Kind, title: String, detail: String = "", jobID: UUID? = nil, bytes: Int64 = 0, observedFreeBytes: Int64 = 0, timestamp: Date = Date()) {
        id = UUID(); self.kind = kind; self.title = String(title.prefix(1024)); self.detail = String(detail.prefix(4096))
        self.jobID = jobID; self.bytes = max(0, bytes); self.observedFreeBytes = max(0, observedFreeBytes); self.timestamp = timestamp
    }
}
private final class ActivityConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close(handle) }
}
/// Private, persistent history of observed actions. Never fabricates completion timestamps for old jobs.
public actor ActivityLedger {
    private let connection: ActivityConnection
    private var db: OpaquePointer { connection.handle }
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = try FileSafety.openDirectory(directory); defer { close(folder) }
        var info = stat()
        guard fstat(folder, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw NestError.unsafePath("activity directory must be private") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("activity.sqlite").path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { throw NestError.database("cannot open activity history") }
        connection = ActivityConnection(handle); sqlite3_busy_timeout(handle, 5000)
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS activity (id TEXT PRIMARY KEY, dedup TEXT UNIQUE, payload TEXT NOT NULL);", nil, nil, nil) == SQLITE_OK else { throw NestError.database("activity migration failed") }
    }
    public func append(_ event: StorageActivity, deduplicationKey: String? = nil) throws {
        let payload = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO activity(id,dedup,payload) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("activity prepare failed") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, event.id.uuidString, -1, transient)
        if let deduplicationKey { sqlite3_bind_text(statement, 2, String(deduplicationKey.prefix(2048)), -1, transient) } else { sqlite3_bind_null(statement, 2) }
        sqlite3_bind_text(statement, 3, payload, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NestError.database("cannot record activity") }
    }
    public func events(limit: Int = 100, offset: Int = 0) throws -> [StorageActivity] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM activity ORDER BY rowid DESC LIMIT ? OFFSET ?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("activity read failed") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(min(500, max(1, limit)))); sqlite3_bind_int64(statement, 2, Int64(max(0, offset)))
        var values: [StorageActivity] = [], result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let payload = sqlite3_column_text(statement, 0) else { throw NestError.database("invalid activity") }
            values.append(try JSONDecoder().decode(StorageActivity.self, from: Data(String(cString: payload).utf8)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw NestError.database("incomplete activity read") }
        return values
    }
    public func count() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM activity", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("activity count failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NestError.database("activity count failed") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

/// A persisted deadline; scheduling does not grant authority to scan any new folder.
public struct RecommendationSchedule: Codable, Sendable, Equatable {
    public enum Frequency: Int, CaseIterable, Codable, Sendable { case daily = 1, weekly = 7, monthly = 30 }
    public var enabled = false
    public var frequency: Frequency = .weekly
    public var lastCompleted: Date?
    public init() {}
    public func nextDue(now: Date = Date()) -> Date? {
        guard enabled else { return nil }
        return (lastCompleted ?? now).addingTimeInterval(Double(frequency.rawValue) * 86_400)
    }
    public func isDue(now: Date = Date()) -> Bool {
        guard enabled, let lastCompleted else { return enabled }
        return now.timeIntervalSince(lastCompleted) >= Double(frequency.rawValue) * 86_400
    }
}
