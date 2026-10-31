import Foundation
import CSQLite
import CryptoKit
import Darwin

private enum CatalogFiles {
    static let members = ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm", "catalog.sqlite-journal"]
    static func privateDirectory(_ directory: URL) throws -> Int32 {
        guard directory.isFileURL else { throw NestError.unsafePath("catalog must use a local directory") }
        var ancestor = directory.standardizedFileURL, missing: [String] = [], info = stat()
        while lstat(ancestor.path, &info) != 0 {
            guard errno == ENOENT, ancestor.path != "/" else { throw NestError.unsafePath("catalog directory unavailable") }
            missing.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
        var fd = try FileSafety.openDirectory(ancestor)
        do {
            for name in missing.reversed() {
                guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else { throw NestError.unsafePath("cannot create private catalog directory") }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw NestError.unsafePath("catalog directory was replaced") }; close(fd); fd = next
            }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { throw NestError.unsafePath("catalog directory must be owned by you and mode 700") }
            guard let security = filesec_init() else { throw NestError.unsafePath("catalog security metadata unavailable") }
            defer { filesec_free(security) }
            var secured = stat(), hasACL: Int32 = 0
            guard fstatx_np(fd, &secured, security) == 0, secured.st_dev == info.st_dev, secured.st_ino == info.st_ino,
                  filesec_query_property(security, FILESEC_ACL, &hasACL) == 0, hasACL == 0 else { throw NestError.unsafePath("catalog directory has unverifiable or additional access permissions") }
            return fd
        } catch { close(fd); throw error }
    }
    static func validate(_ info: stat, allowLegacy: Bool) throws {
        let mode = info.st_mode & 0o7777
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_flags & UInt32(SF_DATALESS) == 0, mode == 0o600 || (allowLegacy && mode == 0o644) else {
            throw NestError.unsafePath("catalog and sidecars must be owned, unlinked regular files with private permissions")
        }
    }
    static func inventory(_ folder: Int32, allowLegacy: Bool) throws -> [String: stat] {
        var values: [String: stat] = [:]
        for name in members {
            var info = stat()
            if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { try validate(info, allowLegacy: allowLegacy); values[name] = info }
            else if errno != ENOENT { throw NestError.unsafePath("catalog member unavailable") }
        }
        return values
    }
    static func prepare(_ folder: Int32) throws -> stat {
        // Validate ALL members before changing even the legitimate main DB.
        let before = try inventory(folder, allowLegacy: true)
        for (name, original) in before where original.st_mode & 0o7777 == 0o644 {
            let fd = openat(folder, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NestError.unsafePath("legacy catalog member unavailable") }; defer { close(fd) }
            var current = stat()
            guard fstat(fd, &current) == 0, current.st_dev == original.st_dev, current.st_ino == original.st_ino else { throw NestError.sourceChanged }
            try validate(current, allowLegacy: true)
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw NestError.unsafePath("cannot privatize legacy catalog permissions") }
        }
        if before["catalog.sqlite"] == nil {
            let fd = openat(folder, "catalog.sqlite", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { close(fd) } else if errno != EEXIST { throw NestError.unsafePath("cannot create private catalog") }
        }
        let current = try inventory(folder, allowLegacy: false)
        guard let main = current["catalog.sqlite"] else { throw NestError.unsafePath("catalog database missing") }
        if let original = before["catalog.sqlite"] { guard main.st_dev == original.st_dev, main.st_ino == original.st_ino else { throw NestError.sourceChanged } }
        return main
    }
    static func verifyOpened(_ handle: OpaquePointer, directory: URL, folder: Int32, original: stat) throws {
        let named = try FileSafety.openDirectory(directory); defer { close(named) }
        var first = stat(), second = stat()
        guard fstat(folder, &first) == 0, fstat(named, &second) == 0, first.st_dev == second.st_dev, first.st_ino == second.st_ino else { throw NestError.sourceChanged }
        let current = try inventory(folder, allowLegacy: false)
        guard let main = current["catalog.sqlite"], main.st_dev == original.st_dev, main.st_ino == original.st_ino else { throw NestError.sourceChanged }
        var moved: Int32 = 1
        guard sqlite3_file_control(handle, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK, moved == 0,
              sqlite3_db_readonly(handle, "main") == 0 else { throw NestError.unsafePath("catalog database identity is uncertain") }
    }
}

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
        self.directory = directory.standardizedFileURL
        let folder = try CatalogFiles.privateDirectory(directory); defer { close(folder) }
        let original = try CatalogFiles.prepare(folder)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(directory.appendingPathComponent("catalog.sqlite").path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let handle else { if let handle { sqlite3_close(handle) }; throw NestError.database("cannot open") }
        // Own every successfully allocated handle immediately, including paths
        // which fail identity checks or migration below.
        let candidate = SQLiteConnection(handle)
        try CatalogFiles.verifyOpened(handle, directory: directory, folder: folder, original: original)
        connection = candidate
        sqlite3_busy_timeout(handle, 5000)
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK else { throw NestError.database("cannot read schema version") }
        let versionResult = sqlite3_step(versionStatement)
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard versionResult == SQLITE_ROW, version <= 3 else { throw NestError.database("this catalog requires a newer CloudNest version") }
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS job_search (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, state TEXT NOT NULL); CREATE INDEX IF NOT EXISTS job_search_state ON job_search(state); CREATE TABLE IF NOT EXISTS recovered_archives (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS folder_recovery_headers (id TEXT PRIMARY KEY, source TEXT NOT NULL, stage TEXT, can_put_back INTEGER NOT NULL, created REAL NOT NULL); CREATE INDEX IF NOT EXISTS folder_recovery_stage ON folder_recovery_headers(stage); CREATE TABLE IF NOT EXISTS folder_recovery_totals (id TEXT PRIMARY KEY, retained INTEGER NOT NULL, observed INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS recovered_folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, created REAL NOT NULL, verified REAL NOT NULL, file_count INTEGER NOT NULL, total_bytes INTEGER NOT NULL, manifest_id TEXT NOT NULL, digest TEXT NOT NULL, payload TEXT NOT NULL); PRAGMA user_version=3;", nil, nil, nil) == SQLITE_OK else { throw NestError.database("migration failed") }
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
        _ = try CatalogFiles.inventory(folder, allowLegacy: false)
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
        guard sqlite3_prepare_v2(db, "SELECT rowid,payload FROM jobs WHERE rowid>? AND json_extract(payload,'$.recovery.stage') IN ('moving','puttingBack','removing') ORDER BY rowid LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovery read failed") }
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
        let uploaded = sqlite3_column_int64(statement, 0), verified = sqlite3_column_int64(statement, 1)
        let fileRetained = sqlite3_column_int64(statement, 2), fileObserved = sqlite3_column_int64(statement, 3)
        var folders: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(retained),0),COALESCE(SUM(observed),0) FROM folder_recovery_totals", -1, &folders, nil) == SQLITE_OK else { throw NestError.database("folder totals failed") }
        defer { sqlite3_finalize(folders) }
        guard sqlite3_step(folders) == SQLITE_ROW else { throw NestError.database("folder totals failed") }
        return CatalogTotals(uploaded: uploaded, verified: verified, inRecovery: fileRetained + sqlite3_column_int64(folders, 0), observedFreeIncrease: fileObserved + sqlite3_column_int64(folders, 1))
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
    public func recoveryJobs(limit: Int = 100, offset: Int = 0) throws -> [ArchiveJob] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM jobs WHERE json_extract(payload,'$.recovery.stage') IN ('moving','puttingBack','retained','needsReview','removing') ORDER BY rowid DESC LIMIT ? OFFSET ?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovery search failed") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(min(500, max(1, limit)))); sqlite3_bind_int64(statement, 2, Int64(max(0, offset)))
        var result: [ArchiveJob] = []; var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { throw NestError.database("invalid recovery row") }
            result.append(try JSONDecoder().decode(ArchiveJob.self, from: Data(String(cString: value).utf8))); step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw NestError.database("incomplete recovery search") }; return result
    }
    public func recoveryJobCount() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM jobs WHERE json_extract(payload,'$.recovery.stage') IN ('moving','puttingBack','retained','needsReview','removing')", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovery count failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NestError.database("recovery count failed") }; return Int(sqlite3_column_int64(statement, 0))
    }
    @discardableResult public func saveRecoveredFolder(_ archive: RecoveredFolderArchive) throws -> Bool {
        let data = try archive.manifest.encoded()
        guard archive.manifestID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw NestError.invalidManifest }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let payload = String(decoding: try JSONEncoder().encode(archive), as: UTF8.self)
        var existing: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT digest FROM recovered_folders WHERE id=?", -1, &existing, nil) == SQLITE_OK else { throw NestError.database("folder recovery read failed") }
        defer { sqlite3_finalize(existing) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(existing, 1, archive.id.uuidString, -1, transient)
        let result = sqlite3_step(existing)
        if result == SQLITE_ROW {
            guard let value = sqlite3_column_text(existing, 0), String(cString: value) == digest else { throw NestError.conflict }; return false
        }
        guard result == SQLITE_DONE else { throw NestError.database("folder recovery read failed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO recovered_folders(id,name,created,verified,file_count,total_bytes,manifest_id,digest,payload) VALUES(?,?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("folder recovery write failed") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, archive.id.uuidString, -1, transient); sqlite3_bind_text(statement, 2, archive.manifest.folderName, -1, transient)
        sqlite3_bind_double(statement, 3, archive.manifest.createdAt.timeIntervalSince1970); sqlite3_bind_double(statement, 4, archive.verifiedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 5, Int64(archive.manifest.files.count)); sqlite3_bind_int64(statement, 6, archive.manifest.files.reduce(0) { $0 + $1.manifest.size })
        sqlite3_bind_text(statement, 7, archive.manifestID, -1, transient); sqlite3_bind_text(statement, 8, digest, -1, transient); sqlite3_bind_text(statement, 9, payload, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NestError.database("folder recovery write failed") }; return true
    }
    public func recoveredFolders(query: String = "", limit: Int = 100, offset: Int = 0) throws -> [RecoveredFolderSummary] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,name,created,verified,file_count,total_bytes,manifest_id FROM recovered_folders WHERE name LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\' OR manifest_id LIKE ? ESCAPE '\\' ORDER BY rowid DESC LIMIT ? OFFSET ?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovered folder search failed") }
        defer { sqlite3_finalize(statement) }; _ = bindSearch(statement, query: query, state: nil)
        sqlite3_bind_int64(statement, 4, Int64(min(500, max(1, limit)))); sqlite3_bind_int64(statement, 5, Int64(max(0, offset)))
        var records: [RecoveredFolderSummary] = []; var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let uuid = UUID(uuidString: String(cString: id)),
                  let name = sqlite3_column_text(statement, 1), let manifestID = sqlite3_column_text(statement, 6) else { throw NestError.database("invalid recovered folder") }
            records.append(RecoveredFolderSummary(id: uuid, folderName: String(cString: name), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), verifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), fileCount: Int(sqlite3_column_int64(statement, 4)), totalBytes: sqlite3_column_int64(statement, 5), manifestID: String(cString: manifestID)))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw NestError.database("incomplete recovered folder search") }; return records
    }
    public func recoveredFolderCount(query: String = "") throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM recovered_folders WHERE name LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\' OR manifest_id LIKE ? ESCAPE '\\'", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovered folder count failed") }
        defer { sqlite3_finalize(statement) }; _ = bindSearch(statement, query: query, state: nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NestError.database("recovered folder count failed") }; return Int(sqlite3_column_int64(statement, 0))
    }
    public func recoveredFolder(_ id: UUID) throws -> RecoveredFolderArchive {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM recovered_folders WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("recovered folder lookup failed") }
        defer { sqlite3_finalize(statement) }; sqlite3_bind_text(statement, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw NestError.invalidManifest }
        let record = try JSONDecoder().decode(RecoveredFolderArchive.self, from: Data(String(cString: value).utf8))
        try record.manifest.validate(); return record
    }

    func saveFolderRecoveryTotals(_ job: FolderArchiveJob) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw NestError.database("folder recovery transaction failed") }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO folder_recovery_totals(id,retained,observed) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET retained=excluded.retained,observed=excluded.observed", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("folder totals update failed") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, job.id.uuidString, -1, transient)
        sqlite3_bind_int64(statement, 2, job.recovery?.retainedBytes ?? 0); sqlite3_bind_int64(statement, 3, job.recovery?.observedFreeSpaceIncrease ?? 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NestError.database("folder totals update failed") }
        var header: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO folder_recovery_headers(id,source,stage,can_put_back,created) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET source=excluded.source,stage=excluded.stage,can_put_back=excluded.can_put_back,created=excluded.created", -1, &header, nil) == SQLITE_OK else { throw NestError.database("folder recovery header update failed") }
        defer { sqlite3_finalize(header) }
        sqlite3_bind_text(header, 1, job.id.uuidString, -1, transient); sqlite3_bind_text(header, 2, job.source.absoluteString, -1, transient)
        if let recovery = job.recovery { sqlite3_bind_text(header, 3, recovery.stage.rawValue, -1, transient) } else { sqlite3_bind_null(header, 3) }
        sqlite3_bind_int(header, 4, job.recovery?.canPutBack == true ? 1 : 0); sqlite3_bind_double(header, 5, job.createdAt.timeIntervalSince1970)
        guard sqlite3_step(header) == SQLITE_DONE, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw NestError.database("folder recovery header commit failed") }
        committed = true
    }
    public func folderRecoveryRecords(limit: Int = 100, offset: Int = 0) throws -> [FolderRecoveryRecord] {
        var statement: OpaquePointer?
        let sql = "SELECT h.id,h.source,h.stage,t.retained,t.observed,h.can_put_back,h.created FROM folder_recovery_headers h JOIN folder_recovery_totals t ON h.id=t.id WHERE h.stage IN ('moving','puttingBack','retained','needsReview','removing') ORDER BY h.created DESC,h.rowid DESC LIMIT ? OFFSET ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw NestError.database("folder recovery search failed") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(min(500, max(1, limit)))); sqlite3_bind_int64(statement, 2, Int64(max(0, offset)))
        var records: [FolderRecoveryRecord] = []; var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let uuid = UUID(uuidString: String(cString: id)),
                  let source = sqlite3_column_text(statement, 1), let url = URL(string: String(cString: source)), url.isFileURL,
                  let stage = sqlite3_column_text(statement, 2), let state = FolderLocalRecovery.Stage(rawValue: String(cString: stage)) else { throw NestError.database("invalid folder recovery header") }
            records.append(FolderRecoveryRecord(id: uuid, source: url, stage: state, retainedBytes: sqlite3_column_int64(statement, 3), observedFreeSpaceIncrease: sqlite3_column_int64(statement, 4), canPutBack: sqlite3_column_int(statement, 5) != 0, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw NestError.database("incomplete folder recovery search") }; return records
    }
    public func folderRecoveryRecordCount() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM folder_recovery_headers WHERE stage IN ('moving','puttingBack','retained','needsReview','removing')", -1, &statement, nil) == SQLITE_OK else { throw NestError.database("folder recovery count failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NestError.database("folder recovery count failed") }; return Int(sqlite3_column_int64(statement, 0))
    }


}
