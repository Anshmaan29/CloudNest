import Testing
import Foundation
import Darwin
import CSQLite
@testable import CloudNestCore

private func legacyPrivateCatalog(_ directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let database = directory.appendingPathComponent("catalog.sqlite")
    var handle: OpaquePointer?
    try #require(sqlite3_open(database.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    try #require(sqlite3_exec(handle, "CREATE TABLE jobs(id TEXT PRIMARY KEY,payload TEXT NOT NULL); CREATE TABLE sentinel(value TEXT NOT NULL); INSERT INTO sentinel VALUES('preserve-me'); PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK)
    try #require(chmod(database.path, 0o644) == 0)
    return database
}
private func mode(_ url: URL) throws -> mode_t {
    var value = stat(); try #require(lstat(url.path, &value) == 0); return value.st_mode & 0o7777
}

@Test func catalogRefusesSymbolicAndHardLinksBeforeMutatingForeignDatabaseOrPermissions() throws {
    let f = try Fixture(); defer { f.clean() }
    let foreign = try legacyPrivateCatalog(f.base.appendingPathComponent("foreign"))
    let original = try Data(contentsOf: foreign)
    for symbolic in [true, false] {
        let subject = f.base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = subject.appendingPathComponent("catalog.sqlite")
        try #require((symbolic ? symlink(foreign.path, alias.path) : link(foreign.path, alias.path)) == 0)
        #expect(throws: (any Error).self) { try Catalog(directory: subject) }
        #expect(try Data(contentsOf: foreign) == original)
        #expect(try mode(foreign) == 0o644)
        #expect(!FileManager.default.fileExists(atPath: subject.appendingPathComponent("catalog.sqlite-wal").path))
    }
}
@Test func catalogChecksAllSidecarsBeforeChangingEvenLegacyMainPermissions() throws {
    let f = try Fixture(); defer { f.clean() }
    let foreign = f.base.appendingPathComponent("foreign-sidecar")
    try Data("unrelated-private-content".utf8).write(to: foreign); try #require(chmod(foreign.path, 0o644) == 0)
    let original = try Data(contentsOf: foreign)
    for suffix in ["-wal", "-shm", "-journal"] {
        for symbolic in [true, false] {
            let subject = f.base.appendingPathComponent(UUID().uuidString), database = try legacyPrivateCatalog(subject)
            let before = try Data(contentsOf: database), alias = subject.appendingPathComponent("catalog.sqlite" + suffix)
            try #require((symbolic ? symlink(foreign.path, alias.path) : link(foreign.path, alias.path)) == 0)
            #expect(throws: (any Error).self) { try Catalog(directory: subject) }
            #expect(try Data(contentsOf: foreign) == original)
            #expect(try mode(foreign) == 0o644)
            #expect(try mode(database) == 0o644)
            #expect(try Data(contentsOf: database) == before)
        }
    }
}
@Test func catalogPrivateDirectoryCreationRejectsSymlinkAncestorsAndPublicFolders() throws {
    let f = try Fixture(); defer { f.clean() }
    let target = f.base.appendingPathComponent("target"), alias = f.base.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try #require(symlink(target.path, alias.path) == 0)
    #expect(throws: (any Error).self) { try Catalog(directory: alias.appendingPathComponent("must-not-create")) }
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("must-not-create").path))
    try #require(chmod(target.path, 0o755) == 0)
    #expect(throws: (any Error).self) { try Catalog(directory: target) }
    #expect(try mode(target) == 0o755)
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("catalog.sqlite").path))
}
@Test func legacyOwnedSingleLinkCatalogUpgradesPrivatelyWithoutLosingExistingData() async throws {
    let f = try Fixture(); defer { f.clean() }
    let subject = f.base.appendingPathComponent("legacy"), database = try legacyPrivateCatalog(subject)
    let catalog = try Catalog(directory: subject)
    #expect(try await catalog.count() == 0)
    #expect(try mode(database) == 0o600)
    for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: subject.appendingPathComponent("catalog.sqlite" + suffix).path) {
        #expect(try mode(subject.appendingPathComponent("catalog.sqlite" + suffix)) == 0o600)
    }
    var raw: OpaquePointer?
    try #require(sqlite3_open_v2(database.path, &raw, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK)
    defer { sqlite3_close(raw) }
    var statement: OpaquePointer?
    try #require(sqlite3_prepare_v2(raw, "SELECT value FROM sentinel", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    try #require(sqlite3_step(statement) == SQLITE_ROW)
    #expect(String(cString: sqlite3_column_text(statement, 0)) == "preserve-me")
    let again = try Catalog(directory: subject)
    #expect(try await again.count() == 0)
}
@Test func catalogRejectsSpecialAndSharedWritableMainFilesWithoutChangingThem() throws {
    let f = try Fixture(); defer { f.clean() }
    let subject = f.base.appendingPathComponent("subject")
    try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = subject.appendingPathComponent("catalog.sqlite")
    try #require(mkfifo(file.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try Catalog(directory: subject) }
    try FileManager.default.removeItem(at: file) // Owned fixture FIFO only.
    try Data("shared-file".utf8).write(to: file); try #require(chmod(file.path, 0o666) == 0)
    #expect(throws: (any Error).self) { try Catalog(directory: subject) }
    #expect(try mode(file) == 0o666)
    #expect(try Data(contentsOf: file) == Data("shared-file".utf8))
}
