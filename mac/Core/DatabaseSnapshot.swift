import Foundation
import Darwin
import CSQLite
import CryptoKit

public struct DatabaseSnapshotLimits: Sendable {
    public var maximumBytes: Int64 = 10_000_000_000
    public var minimumFreeBytes: Int64 = 512_000_000
    public var timeout: TimeInterval = 30
    public var busyTimeout: TimeInterval = 2
    public var pagesPerStep: Int32 = 64
    public init() {}
}
public struct DatabaseSnapshotManifest: Codable, Sendable {
    public let format: String
    public let id: UUID
    public let createdAt: Date
    public let sourceName: String
    public let bytes: Int64
    public let sha256: String
    public let sqliteVersion: String
    public let permitsOriginalCleanup: Bool
    public let payloadName: String
    func validate() throws {
        guard format == "cloudnest-sqlite-v1", !permitsOriginalCleanup, payloadName == DatabaseSnapshot.payloadName,
              bytes >= 512, bytes <= 100_000_000_000, sha256.utf8.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              !sourceName.isEmpty, sourceName.utf8.count <= 1024, !sourceName.contains("/"), !sourceName.contains("\0"), sqliteVersion.utf8.count < 128 else { throw NestError.invalidManifest }
    }
}
public struct DatabaseSnapshotResult: Sendable {
    public let directory: URL
    public let manifestURL: URL
    public let manifest: DatabaseSnapshotManifest
}
public struct DatabaseSnapshotReview: Sendable {
    public let directory: URL
    public let manifest: DatabaseSnapshotManifest
    fileprivate let manifestHash: String
}
private final class SnapshotBudget {
    let deadline: TimeInterval
    init(_ timeout: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + timeout }
    var interrupted: Bool { Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }
    func check() throws { try Task.checkCancellation(); guard !interrupted else { throw NestError.unsafePath("database snapshot exceeded its time budget") } }
}
/// Explicit logical backups only. This type never grants authority to reclaim a source.
public struct DatabaseSnapshot: Sendable {
    public static let payloadName = "database.cloudnest-snapshot"
    public static let manifestName = "CLOUDNEST_DATABASE.json"
    public let protectedRoots: [URL]
    public let limits: DatabaseSnapshotLimits
    public init(protectedRoots: [URL] = [], limits: DatabaseSnapshotLimits = DatabaseSnapshotLimits()) { self.protectedRoots = protectedRoots; self.limits = limits }
    private func checkLimits() throws {
        guard limits.maximumBytes >= 512, limits.maximumBytes <= 100_000_000_000, limits.minimumFreeBytes >= 0,
              limits.timeout.isFinite, limits.timeout > 0, limits.timeout <= 300, limits.busyTimeout.isFinite,
              limits.busyTimeout >= 0, limits.busyTimeout <= 10, limits.pagesPerStep > 0, limits.pagesPerStep <= 1024 else { throw NestError.unsafePath("invalid database snapshot budget") }
    }
    private func directory(_ url: URL, privateOnly: Bool) throws -> Int32 {
        try FileSafety(protectedRoots: protectedRoots).validate(url, root: url)
        var ancestor = url.standardizedFileURL
        while ancestor.path != "/" {
            var marker = stat()
            if lstat(ancestor.appendingPathComponent(".git").path, &marker) == 0 || (FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("HEAD").path) && FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("objects").path) && FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("refs").path)) { throw NestError.unsafePath("database snapshots cannot use repository paths") }
            ancestor.deleteLastPathComponent()
        }
        let fd = try FileSafety.openDirectory(url)
        do {
            var info = stat(), filesystem = statfs()
            guard fstatfs(fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw NestError.unsafePath("SQLite snapshots require a local filesystem") }
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0,
                  !privateOnly || info.st_mode & 0o077 == 0 else { throw NestError.unsafePath("database directory ownership or permissions are unsafe") }
            guard let security = filesec_init() else { throw NestError.invalidResponse }; defer { filesec_free(security) }
            var secured = stat(), hasACL: Int32 = 0
            guard fstatx_np(fd, &secured, security) == 0, secured.st_ino == info.st_ino, secured.st_dev == info.st_dev,
                  filesec_query_property(security, FILESEC_ACL, &hasACL) == 0, hasACL == 0 else { throw NestError.unsafePath("database directory has additional access permissions") }
            return fd
        } catch { close(fd); throw error }
    }
    private static func regular(_ parent: Int32, _ name: String) throws -> stat {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o7777 == 0o600,
              value.st_flags & UInt32(SF_DATALESS) == 0 else { throw NestError.unsafePath("database must be a private, local, owned regular file without links") }; return value
    }
    private static func same(_ first: stat, _ second: stat) -> Bool { first.st_dev == second.st_dev && first.st_ino == second.st_ino }
    private static func requireInventory(_ folder: Int32) throws {
        let duplicate = dup(folder); guard duplicate >= 0 else { throw NestError.invalidResponse }
        guard let listing = fdopendir(duplicate) else { close(duplicate); throw NestError.invalidResponse }; defer { closedir(listing) }
        rewinddir(listing); var names = Set<String>(); errno = 0
        while let entry = readdir(listing) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { names.insert(name); guard names.count <= 2 else { throw NestError.sourceChanged } }
            errno = 0
        }
        guard errno == 0, names == Set([payloadName, manifestName]) else { throw NestError.sourceChanged }
    }
    private static func verifyPath(_ url: URL, parent: Int32, original: stat, database: OpaquePointer? = nil) throws {
        let opened = try FileSafety.openDirectory(url.deletingLastPathComponent()); defer { close(opened) }
        var before = stat(), named = stat()
        guard fstat(parent, &before) == 0, fstat(opened, &named) == 0, same(before, named), same(try regular(parent, url.lastPathComponent), original) else { throw NestError.sourceChanged }
        if let database { var moved: Int32 = 1; guard sqlite3_file_control(database, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK, moved == 0 else { throw NestError.sourceChanged } }
    }
    private static func openDB(_ url: URL, readOnly: Bool, budget: SnapshotBudget) throws -> OpaquePointer {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "mode", value: readOnly ? "ro" : "rw")]
        if readOnly { components.queryItems!.append(URLQueryItem(name: "readonly_shm", value: "1")) }
        var db: OpaquePointer?
        let result = sqlite3_open_v2(components.string!, &db, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; throw NestError.unsafePath("SQLite could not open the selected database safely") }
        sqlite3_busy_timeout(db, 0)
        sqlite3_progress_handler(db, 1000, { pointer in
            guard let pointer else { return 1 }; return Unmanaged<SnapshotBudget>.fromOpaque(pointer).takeUnretainedValue().interrupted ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        return db
    }
    private static func integer(_ db: OpaquePointer, _ pragma: String) throws -> Int64 {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, pragma, -1, &statement, nil) == SQLITE_OK else { throw NestError.invalidManifest }; defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NestError.unsafePath("database is busy, invalid, or cannot be read without recovery") }; return sqlite3_column_int64(statement, 0)
    }
    private static func quickCheck(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { throw NestError.verificationFailed }; defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0), String(cString: text) == "ok", sqlite3_step(statement) == SQLITE_DONE else { throw NestError.verificationFailed }
    }
    private static func hash(_ fd: Int32, maximum: Int64, budget: SnapshotBudget) throws -> (Int64, String) {
        var before = stat(), after = stat(); guard fstat(fd, &before) == 0, before.st_size <= maximum, lseek(fd, 0, SEEK_SET) == 0 else { throw NestError.unsafePath("snapshot exceeds byte budget") }
        var digest = SHA256(), count: Int64 = 0
        let data = UnsafeMutableRawPointer.allocate(byteCount: 1_048_576, alignment: 16); defer { data.deallocate() }
        while true {
            try budget.check(); let readCount = read(fd, data, 1_048_576)
            if readCount < 0 && errno == EINTR { continue }; guard readCount >= 0 else { throw NestError.invalidResponse }; if readCount == 0 { break }
            guard count <= maximum - Int64(readCount) else { throw NestError.unsafePath("snapshot exceeded byte budget") }
            autoreleasepool { digest.update(data: Data(bytes: data, count: readCount)) }; count += Int64(readCount)
        }
        guard fstat(fd, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after), count == before.st_size else { throw NestError.sourceChanged }
        return (count, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func write(_ data: Data, to fd: Int32, synchronize: Bool = true) throws { try data.withUnsafeBytes { value in var offset = 0; while offset < value.count { let count = Darwin.write(fd, value.baseAddress!.advanced(by: offset), value.count - offset); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw NestError.invalidResponse }; offset += count } }; guard !synchronize || fsync(fd) == 0 else { throw NestError.invalidResponse } }
    private func freeSpace(_ fd: Int32, needed: Int64) throws {
        var info = statfs(); guard fstatfs(fd, &info) == 0 else { throw NestError.invalidResponse }
        let available = Int64(clamping: info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
        guard !available.overflow, needed <= available.partialValue, limits.minimumFreeBytes <= available.partialValue - needed else { throw NestError.unsafePath("snapshot needs more free disk space") }
    }
    private static func requireNotOpenHere(_ url: URL) throws {
        // Reusing a same-process writable WAL mapping defeats readonly_shm.
        let process = Process(), output = Pipe(), errors = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(getpid()), "-t", "--", url.path]; process.standardOutput = output; process.standardError = errors
        try process.run(); defer { if process.isRunning { process.terminate() } }; let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { try Task.checkCancellation(); usleep(10_000) }
        guard !process.isRunning else { process.terminate(); throw NestError.unsafePath("could not verify existing database handles") }
        guard [0, 1].contains(process.terminationStatus), errors.fileHandleForReading.readDataToEndOfFile().isEmpty, output.fileHandleForReading.readDataToEndOfFile().isEmpty else { throw NestError.unsafePath("close this database inside CloudNest before snapshotting it; external applications may keep writing") }
    }
    public func create(source: URL, to destination: URL, onProgress: @Sendable (Int64) -> Void = { _ in }) throws -> DatabaseSnapshotResult {
        try checkLimits(); let budget = SnapshotBudget(limits.timeout); defer { withExtendedLifetime(budget) {} }; try budget.check()
        guard source.isFileURL, source.lastPathComponent.utf8.count <= 1024 else { throw NestError.unsafePath("select one local SQLite file") }
        guard !FileSafety.contains(source.deletingLastPathComponent(), destination) else { throw NestError.unsafePath("choose a destination outside the live database directory") }
        let parent = try directory(source.deletingLastPathComponent(), privateOnly: true); defer { close(parent) }
        let folded = source.standardizedFileURL.path.lowercased()
        guard !protectedRoots.contains(where: { let root = $0.standardizedFileURL.path.lowercased(); return folded == root || folded.hasPrefix(root + "/") }) else { throw NestError.unsafePath("protected database") }
        let original = try Self.regular(parent, source.lastPathComponent)
        guard original.st_size >= 100, original.st_size <= limits.maximumBytes else { throw NestError.unsafePath("source database exceeds byte budget") }
        try Self.requireNotOpenHere(source)
        let headerFD = openat(parent, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard headerFD >= 0 else { throw NestError.sourceChanged }
        var header = [UInt8](repeating: 0, count: 100); let readCount = read(headerFD, &header, 100); close(headerFD)
        guard readCount == 100, Data(header.prefix(16)) == Data("SQLite format 3\0".utf8) else { throw NestError.invalidManifest }
        let wal = header[18] == 2 || header[19] == 2
        var sidecars: [String: stat] = [:]
        if wal { for suffix in ["-wal", "-shm"] { sidecars[suffix] = try Self.regular(parent, source.lastPathComponent + suffix) } }
        var journal = stat(); guard fstatat(parent, source.lastPathComponent + "-journal", &journal, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else { throw NestError.unsafePath("source rollback recovery or write is in progress; use its application first") }
        let input = try Self.openDB(source, readOnly: true, budget: budget); defer { sqlite3_close(input) }
        try Self.verifyPath(source, parent: parent, original: original, database: input)
        guard sqlite3_db_readonly(input, "main") == 1, sqlite3_exec(input, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA cache_size=-2048; BEGIN;", nil, nil, nil) == SQLITE_OK else { throw NestError.unsafePath("source cannot establish a read-only snapshot") }
        defer { sqlite3_exec(input, "ROLLBACK", nil, nil, nil) }
        let pageSize = try Self.integer(input, "PRAGMA page_size"), pages = try Self.integer(input, "PRAGMA page_count")
        guard pageSize >= 512, pageSize <= 65536, pages > 0, pages <= limits.maximumBytes / pageSize else { throw NestError.unsafePath("logical database exceeds byte budget") }
        return try produce(destination: destination, sourceName: source.lastPathComponent, budget: budget, expectedBytes: pages * pageSize, onProgress: onProgress) { outputURL, stage, identity in
            let output = try Self.openDB(outputURL, readOnly: false, budget: budget); defer { sqlite3_close(output) }
            try Self.verifyPath(outputURL, parent: stage, original: identity, database: output)
            guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw NestError.unsafePath("SQLite backup could not begin") }
            var finished = false; defer { if !finished { sqlite3_backup_finish(backup) } }
            var busySince: TimeInterval?
            while true {
                try budget.check(); try Self.verifyPath(source, parent: parent, original: original, database: input)
                for (suffix, identity) in sidecars { guard Self.same(try Self.regular(parent, source.lastPathComponent + suffix), identity) else { throw NestError.sourceChanged } }
                let result = sqlite3_backup_step(backup, limits.pagesPerStep)
                onProgress(Int64(max(0, sqlite3_backup_pagecount(backup) - sqlite3_backup_remaining(backup))) * pageSize)
                if result == SQLITE_DONE { break }
                if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                    let now = ProcessInfo.processInfo.systemUptime; if busySince == nil { busySince = now }
                    guard now - busySince! < limits.busyTimeout else { throw NestError.unsafePath("database remained busy; no snapshot was published") }; usleep(10_000)
                } else { guard result == SQLITE_OK else { throw NestError.unsafePath("SQLite backup failed without publishing a partial snapshot") }; busySince = nil }
                try freeSpace(stage, needed: 0)
            }
            let result = sqlite3_backup_finish(backup); finished = true; guard result == SQLITE_OK else { throw NestError.verificationFailed }
            try Self.verifyPath(source, parent: parent, original: original, database: input)
            guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;", nil, nil, nil) == SQLITE_OK else { throw NestError.verificationFailed }
        }
    }
    private func produce(destination: URL, sourceName: String, budget: SnapshotBudget, expectedBytes: Int64, expectedSHA256: String? = nil, onProgress: @Sendable (Int64) -> Void, fill: (URL, Int32, stat) throws -> Void) throws -> DatabaseSnapshotResult {
        let parent = try directory(destination, privateOnly: false); defer { close(parent) }; try freeSpace(parent, needed: expectedBytes)
        if mkdirat(parent, ".cloudnest-recovery", 0o700) != 0 && errno != EEXIST { throw NestError.unsafePath("cannot reserve snapshot staging") }
        let recovery = openat(parent, ".cloudnest-recovery", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard recovery >= 0 else { throw NestError.unsafePath("snapshot staging unavailable") }; defer { close(recovery) }
        var info = stat(); guard fstat(recovery, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw NestError.unsafePath("snapshot staging must be private") }
        guard let security = filesec_init() else { throw NestError.invalidResponse }; defer { filesec_free(security) }
        var secured = stat(), hasACL: Int32 = 0
        guard fstatx_np(recovery, &secured, security) == 0, Self.same(info, secured), filesec_query_property(security, FILESEC_ACL, &hasACL) == 0, hasACL == 0 else { throw NestError.unsafePath("snapshot staging has additional access permissions") }
        let id = UUID(), name = "sqlite-" + id.uuidString
        guard mkdirat(recovery, name, 0o700) == 0 else { throw NestError.conflict }
        let stage = openat(recovery, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard stage >= 0 else { throw NestError.sourceChanged }; defer { close(stage) }
        let url = destination.appendingPathComponent(".cloudnest-recovery").appendingPathComponent(name), payload = url.appendingPathComponent(Self.payloadName)
        let reserved = openat(stage, Self.payloadName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard reserved >= 0 else { throw NestError.conflict }
        let identity: stat
        do { identity = try Self.regular(stage, Self.payloadName); close(reserved) } catch { close(reserved); throw error }
        // Reserve the only optional persistent SQLite scratch member ourselves;
        // SQLite may leave its SHM file behind after converting a WAL backup.
        let shmName = Self.payloadName + "-shm"
        let shmFD = openat(stage, shmName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard shmFD >= 0 else { throw NestError.conflict }
        let ownedSHM: stat
        do { ownedSHM = try Self.regular(stage, shmName); close(shmFD) } catch { close(shmFD); throw error }
        try fill(payload, stage, identity); try budget.check()
        let scratchAfterBackup = try? Self.regular(stage, shmName)
        var output: OpaquePointer? = try Self.openDB(payload, readOnly: true, budget: budget); defer { if let output { sqlite3_close(output) } }
        guard sqlite3_exec(output, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil) == SQLITE_OK else { throw NestError.verificationFailed }
        try Self.quickCheck(output!); try Self.verifyPath(payload, parent: stage, original: identity, database: output)
        guard sqlite3_close(output) == SQLITE_OK else { throw NestError.verificationFailed }; output = nil
        var leftover = stat()
        if fstatat(stage, shmName, &leftover, AT_SYMLINK_NOFOLLOW) == 0 {
            let scratch = openat(stage, shmName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard scratch >= 0 else { throw NestError.sourceChanged }; defer { close(scratch) }
            var opened = stat()
            guard let scratchAfterBackup, fstat(scratch, &opened) == 0, Self.same(opened, ownedSHM),
                  FileSafety.identity(opened) == FileSafety.identity(scratchAfterBackup),
                  FileSafety.identity(try Self.regular(stage, shmName)) == FileSafety.identity(opened), unlinkat(stage, shmName, 0) == 0 else { throw NestError.sourceChanged }
        } else if errno != ENOENT { throw NestError.sourceChanged }
        let fd = openat(stage, Self.payloadName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw NestError.sourceChanged }; defer { close(fd) }
        guard Self.same(try Self.regular(stage, Self.payloadName), identity), fsync(fd) == 0 else { throw NestError.sourceChanged }
        let (bytes, digest) = try Self.hash(fd, maximum: limits.maximumBytes, budget: budget)
        if let expectedSHA256 { guard bytes == expectedBytes, digest == expectedSHA256 else { throw NestError.verificationFailed } }
        let manifest = DatabaseSnapshotManifest(format: "cloudnest-sqlite-v1", id: id, createdAt: Date(), sourceName: sourceName, bytes: bytes, sha256: digest, sqliteVersion: String(cString: sqlite3_libversion()), permitsOriginalCleanup: false, payloadName: Self.payloadName)
        try manifest.validate()
        let metadata = openat(stage, Self.manifestName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard metadata >= 0 else { throw NestError.conflict }; defer { close(metadata) }
        try Self.write(try JSONEncoder().encode(manifest), to: metadata)
        var writtenManifest = stat(); guard fstat(metadata, &writtenManifest) == 0, FileSafety.identity(try Self.regular(stage, Self.manifestName)) == FileSafety.identity(writtenManifest) else { throw NestError.sourceChanged }
        try Self.requireInventory(stage)
        try Self.verifyPath(payload, parent: stage, original: identity)
        let selected = try directory(destination, privateOnly: false); defer { close(selected) }; var first = stat(), second = stat()
        var staged = stat(), namedStage = stat()
        guard fstat(stage, &staged) == 0, fstatat(recovery, name, &namedStage, AT_SYMLINK_NOFOLLOW) == 0, Self.same(staged, namedStage),
              fstat(parent, &first) == 0, fstat(selected, &second) == 0, Self.same(first, second), fsync(stage) == 0,
              renameatx_np(recovery, name, parent, "SQLiteSnapshot-" + id.uuidString, UInt32(RENAME_EXCL)) == 0 else { throw NestError.conflict }
        guard fsync(recovery) == 0, fsync(parent) == 0 else { throw NestError.unsafePath("snapshot was published but filesystem synchronization was uncertain; retain and inspect it") }
        onProgress(bytes)
        let published = destination.appendingPathComponent("SQLiteSnapshot-" + id.uuidString)
        return DatabaseSnapshotResult(directory: published, manifestURL: published.appendingPathComponent(Self.manifestName), manifest: manifest)
    }
    public static func review(directory: URL) throws -> DatabaseSnapshotReview {
        let driver = DatabaseSnapshot(), folder = try driver.directory(directory, privateOnly: true); defer { close(folder) }
        try requireInventory(folder)
        let fd = openat(folder, manifestName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw NestError.invalidManifest }; defer { close(fd) }
        let info = try regular(folder, manifestName); guard info.st_size <= 16384 else { throw NestError.invalidManifest }
        var before = stat(), after = stat(); guard fstat(fd, &before) == 0, same(info, before) else { throw NestError.sourceChanged }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false); let data = try handle.read(upToCount: 16385) ?? Data()
        guard data.count <= 16384, fstat(fd, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after) else { throw NestError.sourceChanged }
        let manifest = try JSONDecoder().decode(DatabaseSnapshotManifest.self, from: data); try manifest.validate()
        return DatabaseSnapshotReview(directory: directory, manifest: manifest, manifestHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    public func restore(approved: DatabaseSnapshotReview, to destination: URL, onProgress: @Sendable (Int64) -> Void = { _ in }) throws -> DatabaseSnapshotResult {
        try checkLimits(); let budget = SnapshotBudget(limits.timeout); defer { withExtendedLifetime(budget) {} }
        guard !FileSafety.contains(approved.directory, destination) else { throw NestError.unsafePath("choose a restore destination outside the selected backup") }
        let folder = try directory(approved.directory, privateOnly: true); defer { close(folder) }
        let current = try Self.review(directory: approved.directory); guard current.manifestHash == approved.manifestHash else { throw NestError.sourceChanged }
        let original = try Self.regular(folder, Self.payloadName), payload = approved.directory.appendingPathComponent(Self.payloadName)
        let fd = openat(folder, Self.payloadName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw NestError.sourceChanged }
        let content: (Int64, String)
        do {
            content = try Self.hash(fd, maximum: limits.maximumBytes, budget: budget)
            var header = [UInt8](repeating: 0, count: 100)
            guard lseek(fd, 0, SEEK_SET) == 0, read(fd, &header, 100) == 100, Data(header.prefix(16)) == Data("SQLite format 3\0".utf8), header[18] == 1, header[19] == 1 else { throw NestError.invalidManifest }
            close(fd)
        } catch { close(fd); throw error }
        guard content.0 == approved.manifest.bytes, content.1 == approved.manifest.sha256 else { throw NestError.verificationFailed }
        let input = try Self.openDB(payload, readOnly: true, budget: budget); defer { sqlite3_close(input) }
        try Self.verifyPath(payload, parent: folder, original: original, database: input); try Self.quickCheck(input)
        return try produce(destination: destination, sourceName: approved.manifest.sourceName, budget: budget, expectedBytes: content.0, expectedSHA256: approved.manifest.sha256, onProgress: onProgress) { payloadURL, stage, identity in
            let sourceFD = openat(folder, Self.payloadName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw NestError.sourceChanged }; defer { close(sourceFD) }
            guard Self.same(try Self.regular(folder, Self.payloadName), original) else { throw NestError.sourceChanged }
            let target = openat(stage, Self.payloadName, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard target >= 0 else { throw NestError.sourceChanged }; defer { close(target) }
            try Self.verifyPath(payloadURL, parent: stage, original: identity)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_048_576, alignment: 16); defer { buffer.deallocate() }
            var total: Int64 = 0, hash = SHA256()
            while true {
                try budget.check(); let count = read(sourceFD, buffer, 1_048_576)
                if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw NestError.invalidResponse }; if count == 0 { break }
                guard total <= approved.manifest.bytes - Int64(count) else { throw NestError.sourceChanged }
                try autoreleasepool { let data = Data(bytes: buffer, count: count); hash.update(data: data); try Self.write(data, to: target, synchronize: false) }
                total += Int64(count); onProgress(total)
            }
            guard fsync(target) == 0, total == approved.manifest.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == approved.manifest.sha256 else { throw NestError.verificationFailed }
            let check = try Self.hash(sourceFD, maximum: limits.maximumBytes, budget: budget)
            guard check.0 == content.0, check.1 == content.1 else { throw NestError.sourceChanged }
        }
    }
}
