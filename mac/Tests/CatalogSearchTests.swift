import Testing
import Foundation
import CSQLite
@testable import CloudNestCore

@Test func catalogSearchMatchesNamesLiterallyAndPaginatesWholeCatalog() async throws {
    let f = try Fixture(); defer { f.clean() }
    let snapshot = try FileSafety().snapshot(f.source, root: f.base)
    var first = ArchiveJob(source: f.base.appendingPathComponent("Report 100%_done.mov"), approvedRoot: f.base, snapshot: snapshot)
    first.state = .verified
    try await f.catalog.save(first)
    for _ in 0..<505 { try await f.catalog.save(ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: snapshot)) }
    #expect(try await f.catalog.count() == 506)
    #expect(try await f.catalog.search(query: "REPORT 100%_done").map(\.id) == [first.id])
    #expect(try await f.catalog.search(query: "%_").map(\.id) == [first.id])
    #expect(try await f.catalog.search(query: "' OR 1=1 --").isEmpty)
    #expect(try await f.catalog.search(query: "", state: .verified).map(\.id) == [first.id])
    #expect(try await f.catalog.count(state: .queued) == 505)
    #expect(try await f.catalog.search(query: "", limit: 9999).count == 500)
    #expect(try await f.catalog.search(query: "", limit: 50, offset: 500).count == 6)
    first.state = .uploading; try await f.catalog.save(first)
    #expect(try await f.catalog.count(state: .verified) == 0)
    #expect(try await f.catalog.count(state: .uploading) == 1)
}

@Test func recoveryReconcilesJobsOlderThanLatestFiveHundred() async throws {
    let f = try Fixture(); defer { f.clean() }
    let snapshot = try FileSafety().snapshot(f.source, root: f.base)
    var oldest = ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: snapshot)
    oldest.recovery = LocalRecovery(stage: .moving)
    try await f.catalog.save(oldest)
    for _ in 0..<501 { try await f.catalog.save(ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: snapshot)) }
    #expect(try await f.catalog.jobs().contains { $0.id == oldest.id } == false)
    try await f.coordinator.reconcileRecovery()
    #expect(try await f.catalog.job(oldest.id).recovery == nil)
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func recoveredRecordsAreIdempotentRejectConflictsAndNeverBecomeCleanupJobs() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    let manifest = ArchiveManifest(job: job, driveFileID: "remote-file")
    let fresh = try Catalog(directory: f.base.appendingPathComponent("fresh-catalog"))
    #expect(try await fresh.saveRecovered(RecoveredArchive(manifest: manifest, manifestID: "manifest-one")))
    #expect(try await fresh.saveRecovered(RecoveredArchive(manifest: manifest, manifestID: "duplicate-manifest")) == false)
    #expect(try await fresh.recoveredCount() == 1)
    #expect(try await fresh.recoveredArchives(query: "ORIGINAL").first?.id == job.id)
    #expect(try await fresh.count() == 0)
    #expect(try await fresh.totals().verified == 0)
    await #expect(throws: (any Error).self) { try await fresh.job(job.id) }
    var changed = try JSONSerialization.jsonObject(with: manifest.encoded()) as! [String: Any]
    changed["driveFileID"] = "different-object"
    let conflicting = try ArchiveManifest.decode(JSONSerialization.data(withJSONObject: changed))
    await #expect(throws: (any Error).self) { try await fresh.saveRecovered(RecoveredArchive(manifest: conflicting, manifestID: "conflict")) }
    #expect(try await fresh.recoveredArchives().first?.manifest.driveFileID == "remote-file")
}

@Test func legacyCatalogGainsSearchIndexWithoutChangingJobState() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    var raw: OpaquePointer?
    #expect(sqlite3_open(f.base.appendingPathComponent("catalog/catalog.sqlite").path, &raw) == SQLITE_OK)
    defer { sqlite3_close(raw) }
    #expect(sqlite3_exec(raw, "DROP TABLE job_search; PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK)
    let upgraded = try Catalog(directory: f.base.appendingPathComponent("catalog"))
    #expect(try await upgraded.search(query: "original").map(\.id) == [job.id])
    #expect(try await upgraded.job(job.id).state == .queued)
}

@Test func recoveryCenterQueryFindsRetainedJobsOlderThanDisplayWindow() async throws {
    let f = try Fixture(); defer { f.clean() }
    var old = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    old.recovery = LocalRecovery(stage: .retained, retainedBytes: old.snapshot.identity.size)
    try await f.catalog.save(old)
    for _ in 0..<501 { try await f.catalog.save(ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: old.snapshot)) }
    #expect(try await f.catalog.jobs().allSatisfy { $0.id != old.id })
    #expect(try await f.catalog.recoveryJobCount() == 1)
    #expect(try await f.catalog.recoveryJobs(limit: 1).first?.id == old.id)
    #expect(try await f.catalog.recoveryJobs(offset: 1).isEmpty)
}
