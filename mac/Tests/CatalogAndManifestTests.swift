import Testing
import Foundation
@testable import CloudNestCore

@Test func catalogPagesStayBoundedAndOldJobsRemainAddressable() async throws {
    let f = try Fixture(); defer { f.clean() }
    let snapshot = try FileSafety().snapshot(f.source, root: f.base)
    var earliest = ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: snapshot)
    earliest.state = .verified; try await f.catalog.save(earliest)
    for _ in 0..<500 { try await f.catalog.save(ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: snapshot)) }
    #expect(try await f.catalog.jobs().count == 500)
    #expect(try await f.catalog.jobs(offset: 500).count == 1)
    #expect(try await f.catalog.job(earliest.id).id == earliest.id)
    #expect(try await f.catalog.totals().uploaded == snapshot.identity.size)
}

@Test func portableManifestImportIsBoundedAndRejectsLinks() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    let manifest = ArchiveManifest(job: job, driveFileID: "test-remote")
    let good = f.base.appendingPathComponent("recovery.json")
    try manifest.encoded().write(to: good)
    #expect(try ArchiveManifest.read(from: good).sha256 == job.snapshot.sha256)
    let link = f.base.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
    #expect(throws: (any Error).self) { try ArchiveManifest.read(from: link) }
    let large = f.base.appendingPathComponent("large.json")
    try Data(repeating: 0x20, count: 131_073).write(to: large)
    #expect(throws: (any Error).self) { try ArchiveManifest.read(from: large) }
}

@Test func knownDatabaseDirectoryIsExcluded() throws {
    let f = try Fixture(); defer { f.clean() }
    let root = f.base.appendingPathComponent("database")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("16".utf8).write(to: root.appendingPathComponent("PG_VERSION"))
    try Data("live opaque storage".utf8).write(to: root.appendingPathComponent("12345"))
    #expect(throws: (any Error).self) { try FileScanner().scan(root: root, minimumBytes: 0) }
}

@Test func cleanupRefusesFileOpenInAnotherProcess() throws {
    let f = try Fixture(); defer { f.clean() }
    try FileSafety.requireUnused(f.source)
    let reader = Process(); reader.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    reader.arguments = ["-f", f.source.path]; reader.standardOutput = FileHandle.nullDevice; reader.standardError = FileHandle.nullDevice
    try reader.run(); defer { reader.terminate(); reader.waitUntilExit() }
    var refused = false
    for _ in 0..<10 {
        do { try FileSafety.requireUnused(f.source) }
        catch NestError.unsafePath(let reason) { refused = reason.contains("open in another process"); break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(refused)
}

@Test func protectedPathCaseAliasesDoNotBypassExclusions() throws {
    let f = try Fixture(); defer { f.clean() }
    let alias = URL(fileURLWithPath: f.base.path.uppercased())
    #expect(throws: (any Error).self) { try FileSafety(protectedRoots: [alias]).snapshot(f.source, root: f.base) }
    // Approval containment remains strict on case-sensitive volumes.
    #expect(!FileSafety.contains(URL(fileURLWithPath: "/approved/Root"), URL(fileURLWithPath: "/approved/root/file")))
}
