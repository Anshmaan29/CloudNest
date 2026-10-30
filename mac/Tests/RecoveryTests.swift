import Testing
import Foundation
@testable import CloudNestCore

@Test func retainedRecoveryCanPutBackWithoutOverwrite() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    try await f.coordinator.moveToRecovery(job.id)
    #expect(!FileManager.default.fileExists(atPath: f.source.path))
    #expect(FileManager.default.fileExists(atPath: RecoveryFiles.payload(job).path))
    #expect(try await f.catalog.job(job.id).recovery?.stage == .retained)
    try Data("new original".utf8).write(to: f.source)
    await #expect(throws: (any Error).self) { try await f.coordinator.putBackOriginal(job.id) }
    #expect(try Data(contentsOf: f.source) == Data("new original".utf8))
    try FileManager.default.removeItem(at: f.source) // Test-owned conflicting fixture only.
    try await f.coordinator.putBackOriginal(job.id)
    #expect(try await f.catalog.job(job.id).recovery == nil)
    // A known put-back updates identity after rename; it can be safely staged again.
    try await f.coordinator.moveToRecovery(job.id)
    #expect(try await f.catalog.job(job.id).recovery?.stage == .retained)
}

@Test func removalTouchesOnlyVerifiedManagedPayload() async throws {
    let f = try Fixture(size: 2 * 1024 * 1024); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id); try await f.coordinator.moveToRecovery(job.id)
    let other = RecoveryFiles.directory(job).appendingPathComponent("unrelated.txt")
    try Data("unrelated".utf8).write(to: other)
    try await f.coordinator.permanentlyRemoveRecovery(job.id)
    let completed = try await f.catalog.job(job.id)
    #expect(completed.recovery?.stage == .removed)
    #expect(completed.recovery?.retainedBytes == 0)
    #expect(!FileManager.default.fileExists(atPath: RecoveryFiles.payload(job).path))
    #expect(try Data(contentsOf: other) == Data("unrelated".utf8))
    let restore = f.base.appendingPathComponent("after-removal"); try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: false)
    let recovered = try await f.coordinator.restore(manifest: ArchiveManifest(job: completed, driveFileID: completed.remoteID!), destination: restore)
    #expect(try FileSafety().snapshot(recovered, root: restore).sha256 == job.snapshot.sha256)
}

@Test func uncertainCloudVerificationBlocksBothCleanupSteps() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    await f.remote.configure(omit: true)
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: f.source.path))
    await f.remote.configure()
    try await f.coordinator.moveToRecovery(job.id)
    await f.remote.configure(omit: true)
    await #expect(throws: (any Error).self) { try await f.coordinator.permanentlyRemoveRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: RecoveryFiles.payload(job).path))
}

@Test func changedRetainedDataIsPreservedAndRemovalBlocked() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id); try await f.coordinator.moveToRecovery(job.id)
    let payload = RecoveryFiles.payload(job)
    try Data("changed retained content".utf8).write(to: payload)
    await #expect(throws: (any Error).self) { try await f.coordinator.permanentlyRemoveRecovery(job.id) }
    #expect(try Data(contentsOf: payload) == Data("changed retained content".utf8))
    #expect(try await f.catalog.job(job.id).recovery?.stage == .needsReview)
    try await f.coordinator.putBackOriginal(job.id)
    #expect(try Data(contentsOf: f.source) == Data("changed retained content".utf8))
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(job.id) }
}

@Test func interruptedCleanupReconcilesWithoutAutonomousDeletion() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id); try await f.coordinator.moveToRecovery(job.id)
    var interrupted = try await f.catalog.job(job.id)
    interrupted.recovery?.stage = .removing; try await f.catalog.save(interrupted)
    try await f.coordinator.reconcileRecovery()
    #expect(try await f.catalog.job(job.id).recovery?.stage == .retained)
    #expect(FileManager.default.fileExists(atPath: RecoveryFiles.payload(job).path))
}

@Test func protectionAddedAfterUploadBlocksCleanup() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    let protected = ArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets, safety: FileSafety(protectedRoots: [f.base]))
    await #expect(throws: (any Error).self) { try await protected.moveToRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func duplicateHashingAndAgeRulesAreBounded() throws {
    let f = try Fixture(); defer { f.clean() }
    let root = f.base.appendingPathComponent("scan"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let a = root.appendingPathComponent("a.bin"), b = root.appendingPathComponent("b.bin"), c = root.appendingPathComponent("c.bin")
    try Data(repeating: 1, count: 4096).write(to: a); try Data(repeating: 1, count: 4096).write(to: b)
    try Data(repeating: 2, count: 4096).write(to: c)
    let scanner = FileScanner(), report = try scanner.scan(root: root, minimumBytes: 0)
    #expect(try scanner.duplicateGroups(report, root: root).count == 1)
    #expect(try scanner.duplicateGroups(report, root: root, byteBudget: 4096).isEmpty)
    #expect(try scanner.scan(root: root, minimumBytes: 0, minimumAgeDays: 10).candidates.isEmpty)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 86_400)], ofItemAtPath: a.path)
    #expect(try scanner.scan(root: root, minimumBytes: 0, minimumAgeDays: 10).candidates.count == 1)
}
