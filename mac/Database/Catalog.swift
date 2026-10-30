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
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK else { throw NestError.database("cannot read schema version") }
        let versionResult = sqlite3_step(versionStatement)
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard versionResult == SQLITE_ROW, version <= 2 else { throw NestError.database("this catalog requires a newer CloudNest version") }
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS job_search (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, state TEXT NOT NULL); CREATE INDEX IF NOT EXISTS job_search_state ON job_search(state); CREATE TABLE IF NOT EXISTS recovered_archives (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, payload TEXT NOT NULL); PRAGMA user_version=2;", nil, nil, nil) == SQLITE_OK else { throw NestError.database("migration failed") }
        // One-row-at-a-time migration: never materialize an entire legacy catalog.
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw NestError.database("search migration transaction failed") }
        var migrated = false
        defer { if !migrated { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT payload FROM jobs WHERE id NOT IN (SELECT id FROM job_search)", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("search migration failed") }
        defer { sqlite3_finalize(statement) }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { throw NestError.database("invalid legacy job") }
            let job = try JSONDecoder().decode(ArchiveJob.self, from: Data(String(cString: value).utf8))
            try Self.saveSearch(handle, job)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw NestError.database("search migration failed") }
        guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw NestError.database("search migration commit failed") }
        migrated = true
    }
    public func save(_ job: ArchiveJob) throws {
        let payload = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw NestError.database("transaction failed") }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO jobs(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("prepare failed") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, job.id.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, payload, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NestError.database("write failed") }
        try Self.saveSearch(db, job)
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw NestError.database("commit failed") }
        committed = true
    }
    private static func saveSearch(_ db: OpaquePointer, _ job: ArchiveJob) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO job_search(id,name,path,state) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,path=excluded.path,state=excluded.state", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("search prepare failed") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in [job.id.uuidString, job.source.lastPathComponent, job.source.path, job.state.rawValue].enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NestError.database("search update failed") }
    }
    /// Literal, case-insensitive substring matching. SQL wildcard characters remain literal.
    private static func searchPattern(_ query: String) -> String {
        let value = String(query.prefix(1024)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%" + value + "%"
    }
    public func search(query: String, state: TransferState? = nil, limit: Int = 100, offset: Int = 0) throws -> [ArchiveJob] {
        let predicate = "(s.name LIKE ? ESCAPE '\\' OR s.path LIKE ? ESCAPE '\\' OR s.id LIKE ? ESCAPE '\\')" + (state == nil ? "" : " AND s.state=?")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT j.payload FROM jobs j JOIN job_search s ON j.id=s.id WHERE " + predicate + " ORDER BY j.rowid DESC LIMIT ? OFFSET ?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("search failed") }
        defer { sqlite3_finalize(statement) }
        let next = bindSearch(statement, query: query, state: state)
        sqlite3_bind_int64(statement, next, Int64(min(500, max(1, limit))))
        sqlite3_bind_int64(statement, next + 1, Int64(max(0, offset)))
        var result: [ArchiveJob] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { throw NestError.database("invalid row") }
            result.append(try JSONDecoder().decode(ArchiveJob.self, from: Data(String(cString: value).utf8)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw NestError.database("incomplete search") }
        return result
    }
    public func count(query: String = "", state: TransferState? = nil) throws -> Int {
        let predicate = "(s.name LIKE ? ESCAPE '\\' OR s.path LIKE ? ESCAPE '\\' OR s.id LIKE ? ESCAPE '\\')" + (state == nil ? "" : " AND s.state=?")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM job_search s WHERE " + predicate, -1, &statement, nil) == SQLITE_OK else { throw NestError.database("count failed") }
        defer { sqlite3_finalize(statement) }
        _ = bindSearch(statement, query: query, state: state)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NestError.database("count failed") }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func bindSearch(_ statement: OpaquePointer?, query: String, state: TransferState?) -> Int32 {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self), pattern = Self.searchPattern(query)
        for index: Int32 in 1...3 { sqlite3_bind_text(statement, index, pattern, -1, transient) }
        if let state { sqlite3_bind_text(statement, 4, state.rawValue, -1, transient); return 5 }
        return 4
    }
    /// Bounded keyset pages, stable while recovery state is updated in-place.
    public func interruptedRecoveries(afterRowID: Int64 = 0, limit: Int = 100) throws -> (jobs: [ArchiveJob], cursor: Int64?) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid,payload FROM jobs WHERE rowid>? AND json_extract(payload,'$.recovery.stage') IN ('moving','removing') ORDER BY rowid LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovery read failed") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, max(0, afterRowID)); sqlite3_bind_int64(statement, 2, Int64(min(500, max(1, limit))))
        var jobs: [ArchiveJob] = [], cursor: Int64?
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 1) else { throw NestError.database("invalid recovery row") }
            cursor = sqlite3_column_int64(statement, 0)
            jobs.append(try JSONDecoder().decode(ArchiveJob.self, from: Data(String(cString: value).utf8)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw NestError.database("incomplete recovery read") }
        return (jobs, cursor)
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
    /// Idempotent import. Conflicting copies of the same manifest identity never overwrite.
    @discardableResult public func saveRecovered(_ archive: RecoveredArchive) throws -> Bool {
        try archive.manifest.validate()
        guard archive.manifestID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw NestError.invalidManifest }
        var existing: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM recovered_archives WHERE id=?", -1, &existing, nil) == SQLITE_OK else { throw NestError.database("recovery prepare failed") }
        defer { sqlite3_finalize(existing) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(existing, 1, archive.id.uuidString, -1, transient)
        let result = sqlite3_step(existing)
        if result == SQLITE_ROW {
            guard let value = sqlite3_column_text(existing, 0) else { throw NestError.database("invalid recovered record") }
            let previous = try JSONDecoder().decode(RecoveredArchive.self, from: Data(String(cString: value).utf8))
            guard try previous.manifest.encoded() == archive.manifest.encoded() else { throw NestError.conflict }
            return false
        }
        guard result == SQLITE_DONE else { throw NestError.database("recovery lookup failed") }
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO recovered_archives(id,name,path,payload) VALUES(?,?,?,?)", -1, &insert, nil) == SQLITE_OK else { throw NestError.database("recovery prepare failed") }
        defer { sqlite3_finalize(insert) }
        let payload = String(decoding: try JSONEncoder().encode(archive), as: UTF8.self)
        for (index, value) in [archive.id.uuidString, archive.manifest.fileName, archive.manifest.originalPath, payload].enumerated() {
            sqlite3_bind_text(insert, Int32(index + 1), value, -1, transient)
        }
        guard sqlite3_step(insert) == SQLITE_DONE else { throw NestError.database("recovery write failed") }
        return true
    }
    public func recoveredArchives(query: String = "", limit: Int = 100, offset: Int = 0) throws -> [RecoveredArchive] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM recovered_archives WHERE name LIKE ? ESCAPE '\\' OR path LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\' ORDER BY rowid DESC LIMIT ? OFFSET ?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovered search failed") }
        defer { sqlite3_finalize(statement) }
        _ = bindSearch(statement, query: query, state: nil)
        sqlite3_bind_int64(statement, 4, Int64(min(500, max(1, limit)))); sqlite3_bind_int64(statement, 5, Int64(max(0, offset)))
        var records: [RecoveredArchive] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { throw NestError.database("invalid recovered record") }
            records.append(try JSONDecoder().decode(RecoveredArchive.self, from: Data(String(cString: value).utf8)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw NestError.database("incomplete recovered search") }
        return records
    }
    public func recoveredCount(query: String = "") throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM recovered_archives WHERE name LIKE ? ESCAPE '\\' OR path LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\'", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovered count failed") }
        defer { sqlite3_finalize(statement) }
        _ = bindSearch(statement, query: query, state: nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NestError.database("recovered count failed") }
        return Int(sqlite3_column_int64(statement, 0))
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
