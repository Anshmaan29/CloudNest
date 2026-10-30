import Foundation
import CSQLite

public struct CatalogTotals: Sendable {
    public let uploaded: Int64
    public let verified: Int64
    public let inRecovery: Int64
    public let observedFreeIncrease: Int64
}

// FULLMUTEX connection is owned by one actor. The holder closes on final release.
private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close(handle) }
}
public actor Catalog {
    private let connection: SQLiteConnection
    private var db: OpaquePointer { connection.handle }
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("catalog.sqlite").path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NestError.database("cannot open") }
        guard let handle else { throw NestError.database("cannot open") }
        connection = SQLiteConnection(handle)
        sqlite3_busy_timeout(handle, 5000)
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, payload TEXT NOT NULL); PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK else { throw NestError.database("migration failed") }
    }
    public func save(_ job: ArchiveJob) throws {
        let payload = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO jobs(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("prepare failed") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, job.id.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, payload, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NestError.database("write failed") }
    }
    public func jobs(limit: Int = 500, offset: Int = 0) throws -> [ArchiveJob] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM jobs ORDER BY rowid DESC LIMIT ? OFFSET ?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("read failed") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(min(500, max(1, limit))))
        sqlite3_bind_int64(statement, 2, Int64(max(0, offset)))
        var result: [ArchiveJob] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { throw NestError.database("invalid row") }
            result.append(try JSONDecoder().decode(ArchiveJob.self, from: Data(String(cString: value).utf8)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw NestError.database("incomplete read") }
        return result
    }
    public func job(_ id: UUID) throws -> ArchiveJob {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM jobs WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("read failed") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw NestError.invalidManifest }
        return try JSONDecoder().decode(ArchiveJob.self, from: Data(String(cString: value).utf8))
    }
    public func totals() throws -> CatalogTotals {
        let sql = """
        SELECT COALESCE(SUM(CASE WHEN json_extract(payload,'$.state') IN ('uploaded','verified') THEN json_extract(payload,'$.snapshot.identity.size') ELSE 0 END),0),
               COALESCE(SUM(CASE WHEN json_extract(payload,'$.state')='verified' THEN json_extract(payload,'$.snapshot.identity.size') ELSE 0 END),0),
               COALESCE(SUM(json_extract(payload,'$.recovery.retainedBytes')),0),
               COALESCE(SUM(json_extract(payload,'$.recovery.observedFreeSpaceIncrease')),0)
        FROM jobs
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw NestError.database("totals failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NestError.database("totals failed") }
        return CatalogTotals(uploaded: sqlite3_column_int64(statement, 0), verified: sqlite3_column_int64(statement, 1), inRecovery: sqlite3_column_int64(statement, 2), observedFreeIncrease: sqlite3_column_int64(statement, 3))
    }
    public func writeManifest(_ manifest: ArchiveManifest) throws -> URL {
        try manifest.validate()
        let folder = directory.appendingPathComponent("manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(manifest.jobID.uuidString + ".json")
        try manifest.encoded().write(to: url, options: .atomic)
        return url
    }
}
