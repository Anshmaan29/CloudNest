import Testing
import Foundation
import Darwin
import CSQLite
@testable import CloudNestCore

private struct DatabaseFixture {
    let f: Fixture
    let source: URL
    let destination: URL
    init() throws {
        f = try Fixture(); let parent = f.base.appendingPathComponent("LiveDatabase")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        source = parent.appendingPathComponent("records.sqlite"); destination = f.base.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let fd = open(source.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600); try #require(fd >= 0); close(fd)
        var db: OpaquePointer?; try #require(sqlite3_open(source.path, &db) == SQLITE_OK); defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE records(value INTEGER, padding BLOB); INSERT INTO records VALUES(1,zeroblob(50000)),(1,zeroblob(50000));", nil, nil, nil) == SQLITE_OK)
    }
    func published() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix("SQLiteSnapshot-") } }
    func clean() { f.clean() }
}
private final class DatabaseWriter {
    let source: URL
    let ready: URL
    let request: URL
    let acknowledgement: URL
    var pid: pid_t = 0
    var reaped = false
    init(_ source: URL) throws {
        self.source = source; ready = source.appendingPathExtension("ready"); request = source.appendingPathExtension("request"); acknowledgement = source.appendingPathExtension("ack")
        let script = """
        import sqlite3,sys,time,os
        db=sqlite3.connect(sys.argv[1],isolation_level=None)
        db.execute('PRAGMA journal_mode=WAL'); db.execute('PRAGMA wal_autocheckpoint=0')
        db.execute('BEGIN'); db.execute('INSERT INTO records VALUES(2,zeroblob(50000)),(2,zeroblob(50000))'); db.execute('COMMIT')
        open(sys.argv[2],'w').close()
        while True:
          if os.path.exists(sys.argv[3]):
            db.execute('BEGIN'); db.execute('INSERT INTO records VALUES(3,zeroblob(50000)),(3,zeroblob(50000))'); db.execute('COMMIT')
            os.unlink(sys.argv[3]); open(sys.argv[4],'w').close()
          time.sleep(.005)
        """
        var argv = ["/usr/bin/python3", "-c", script, source.path, ready.path, request.path, acknowledgement.path].map { strdup($0) } + [nil]
        var env = [strdup("PATH=/usr/bin:/bin"), nil]; defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var attributes: posix_spawnattr_t?; try #require(posix_spawnattr_init(&attributes) == 0); defer { posix_spawnattr_destroy(&attributes) }
        try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        try #require(argv.withUnsafeMutableBufferPointer { args in env.withUnsafeMutableBufferPointer { values in posix_spawn(&pid, "/usr/bin/python3", nil, &attributes, args.baseAddress!, values.baseAddress!) } } == 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: ready.path) && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if !FileManager.default.fileExists(atPath: ready.path) { stop() }
        try #require(FileManager.default.fileExists(atPath: ready.path))
    }
    func stop() {
        guard !reaped else { return }; _ = kill(pid, SIGKILL); let deadline = ProcessInfo.processInfo.systemUptime + 3; var status: Int32 = 0
        while ProcessInfo.processInfo.systemUptime < deadline { let result = waitpid(pid, &status, WNOHANG); if result == pid || result == -1 && errno == ECHILD { reaped = true; return }; usleep(10_000) }
    }
    deinit { stop() }
    static func commitDuringSnapshot(request: URL, acknowledgement: URL) throws {
        try Data().write(to: request); let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: acknowledgement.path) && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        try #require(FileManager.default.fileExists(atPath: acknowledgement.path))
    }
}
private func countRows(_ file: URL) throws -> Int64 {
    var db: OpaquePointer?; try #require(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK); defer { sqlite3_close(db) }
    var statement: OpaquePointer?; try #require(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM records", -1, &statement, nil) == SQLITE_OK); defer { sqlite3_finalize(statement) }; try #require(sqlite3_step(statement) == SQLITE_ROW); return sqlite3_column_int64(statement, 0)
}
private final class SnapshotOnce: @unchecked Sendable {
    let lock = NSLock(); var done = false
    func once(_ action: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; action() } }
}

@Test func databaseSnapshotIncludesCommittedWALWithoutChangingSourceDatabaseWALOrSHM() throws {
    let f = try DatabaseFixture(); defer { f.clean() }; let writer = try DatabaseWriter(f.source); defer { writer.stop() }
    let paths = [f.source, URL(fileURLWithPath: f.source.path + "-wal"), URL(fileURLWithPath: f.source.path + "-shm")]
    let before = try paths.map { try Data(contentsOf: $0) }
    let snapshot = try DatabaseSnapshot().create(source: f.source, to: f.destination)
    #expect(try countRows(snapshot.directory.appendingPathComponent(DatabaseSnapshot.payloadName)) == 4)
    #expect(try paths.map { try Data(contentsOf: $0) } == before)
    #expect(!snapshot.manifest.permitsOriginalCleanup)
    #expect(try f.published().count == 1)
    #expect(throws: (any Error).self) { try FileSafety().snapshot(f.source, root: f.source.deletingLastPathComponent()) }
    _ = try FileSafety().snapshot(snapshot.directory.appendingPathComponent(DatabaseSnapshot.payloadName), root: snapshot.directory)
}
@Test func databaseSnapshotPinsConsistentReadWhileExternalWALWriterCommits() throws {
    let f = try DatabaseFixture(); defer { f.clean() }; let writer = try DatabaseWriter(f.source); defer { writer.stop() }
    let once = SnapshotOnce(); var limits = DatabaseSnapshotLimits(); limits.pagesPerStep = 1
    let result = try DatabaseSnapshot(limits: limits).create(source: f.source, to: f.destination) { [request = writer.request, acknowledgement = writer.acknowledgement] _ in once.once { try? DatabaseWriter.commitDuringSnapshot(request: request, acknowledgement: acknowledgement) } }
    #expect(FileManager.default.fileExists(atPath: writer.acknowledgement.path))
    #expect(try countRows(result.directory.appendingPathComponent(DatabaseSnapshot.payloadName)) == 4)
    #expect(try countRows(f.source) == 6)
}
@Test func databaseRestoreVerifiesManifestExactBytesAndPublishesOnlyNewFolders() throws {
    let f = try DatabaseFixture(); defer { f.clean() }
    let snapshot = try DatabaseSnapshot().create(source: f.source, to: f.destination), review = try DatabaseSnapshot.review(directory: snapshot.directory)
    let restored = try DatabaseSnapshot().restore(approved: review, to: f.destination)
    #expect(restored.directory != snapshot.directory)
    #expect(restored.manifest.sha256 == snapshot.manifest.sha256 && restored.manifest.bytes == snapshot.manifest.bytes)
    #expect(try countRows(restored.directory.appendingPathComponent(DatabaseSnapshot.payloadName)) == 2)
    #expect(try countRows(f.source) == 2)
    let payload = snapshot.directory.appendingPathComponent(DatabaseSnapshot.payloadName)
    try Data("changed-content".utf8).write(to: payload)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().restore(approved: review, to: f.destination) }
    #expect(try f.published().count == 2)
}
@Test func databaseSnapshotRejectsLinksProtectedPathsUnsafePermissionsAndMalformedSources() throws {
    let f = try DatabaseFixture(); defer { f.clean() }
    #expect(throws: (any Error).self) { try DatabaseSnapshot(protectedRoots: [f.source]).create(source: f.source, to: f.destination) }
    #expect(throws: (any Error).self) { try DatabaseSnapshot(protectedRoots: [f.destination]).create(source: f.source, to: f.destination) }
    let link = f.source.deletingLastPathComponent().appendingPathComponent("alias.sqlite"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().create(source: link, to: f.destination) }
    let hard = f.source.appendingPathExtension("linked"); try FileManager.default.linkItem(at: f.source, to: hard)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().create(source: f.source, to: f.destination) }; try FileManager.default.removeItem(at: hard)
    try #require(chmod(f.source.path, 0o644) == 0)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().create(source: f.source, to: f.destination) }
    try #require(chmod(f.source.path, 0o600) == 0)
    let marker = f.source.deletingLastPathComponent().appendingPathComponent(".git")
    try Data().write(to: marker)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().create(source: f.source, to: f.destination) }; try FileManager.default.removeItem(at: marker)
    try Data(repeating: 0, count: 1000).write(to: f.source)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().create(source: f.source, to: f.destination) }
    #expect(try f.published().isEmpty)
}

@Test func databaseSnapshotNeverOverwritesAConflictingPublishedFolder() throws {
    let f = try DatabaseFixture(); defer { f.clean() }; let once = SnapshotOnce()
    #expect(throws: (any Error).self) {
        try DatabaseSnapshot().create(source: f.source, to: f.destination) { _ in once.once {
            let recovery = f.destination.appendingPathComponent(".cloudnest-recovery")
            if let name = try? FileManager.default.contentsOfDirectory(atPath: recovery.path).first {
                let target = f.destination.appendingPathComponent("SQLiteSnapshot-" + name.dropFirst("sqlite-".count))
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try? Data("retain-user-content".utf8).write(to: target.appendingPathComponent("sentinel"))
            }
        } }
    }
    let name = try #require(f.published().first)
    #expect(try Data(contentsOf: f.destination.appendingPathComponent(name).appendingPathComponent("sentinel")) == Data("retain-user-content".utf8))
}

@Test func databaseSnapshotMidCopyCancellationAndManifestCorrectionPreventPublicationOrRestore() async throws {
    let f = try DatabaseFixture(); defer { f.clean() }
    let job = Task { try DatabaseSnapshot().create(source: f.source, to: f.destination) { _ in withUnsafeCurrentTask { $0?.cancel() } } }
    await #expect(throws: CancellationError.self) { try await job.value }
    #expect(try f.published().isEmpty)
    let result = try DatabaseSnapshot().create(source: f.source, to: f.destination), review = try DatabaseSnapshot.review(directory: result.directory)
    let original = try Data(contentsOf: result.manifestURL); try (original + Data(" ".utf8)).write(to: result.manifestURL)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().restore(approved: review, to: f.destination) }
    #expect(throws: (any Error).self) { try DatabaseSnapshot().create(source: f.source, to: f.source.deletingLastPathComponent()) }
    #expect(try f.published().count == 1)
}
@Test func databaseSnapshotTimeoutCancellationByteAndDiskBudgetsNeverPublishPartialData() async throws {
    let f = try DatabaseFixture(); defer { f.clean() }
    var limits = DatabaseSnapshotLimits(); limits.timeout = 0.00001
    #expect(throws: (any Error).self) { try DatabaseSnapshot(limits: limits).create(source: f.source, to: f.destination) }
    limits = DatabaseSnapshotLimits(); limits.maximumBytes = 1024
    #expect(throws: (any Error).self) { try DatabaseSnapshot(limits: limits).create(source: f.source, to: f.destination) }
    limits = DatabaseSnapshotLimits(); limits.minimumFreeBytes = Int64.max
    #expect(throws: (any Error).self) { try DatabaseSnapshot(limits: limits).create(source: f.source, to: f.destination) }
    let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try DatabaseSnapshot().create(source: f.source, to: f.destination) }
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(try f.published().isEmpty)
}
@Test func databaseSnapshotRefusesOwnProcessConnectionAndMissingWALSidecarsWithoutWritingSource() throws {
    let f = try DatabaseFixture(); defer { f.clean() }
    var db: OpaquePointer?; try #require(sqlite3_open(f.source.path, &db) == SQLITE_OK)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().create(source: f.source, to: f.destination) }; sqlite3_close(db)
    let writer = try DatabaseWriter(f.source); writer.stop()
    let shm = URL(fileURLWithPath: f.source.path + "-shm"), wal = URL(fileURLWithPath: f.source.path + "-wal")
    try FileManager.default.removeItem(at: shm); let before = try Data(contentsOf: wal)
    #expect(throws: (any Error).self) { try DatabaseSnapshot().create(source: f.source, to: f.destination) }
    #expect(!FileManager.default.fileExists(atPath: shm.path)); #expect(try Data(contentsOf: wal) == before)
}
