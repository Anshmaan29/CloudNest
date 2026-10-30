import Testing
import Foundation
import Darwin
@testable import CloudNestCore

extension TestRemote {
    func removeFolderObject(_ id: String) { objects.removeValue(forKey: id) }
    func replaceFolderObject(_ id: String, data: Data) { objects[id] = data }
}

private struct FolderCleanupFixture {
    let f: Fixture
    let source: URL
    var coordinator: FolderArchiveCoordinator { FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets) }
    init() throws {
        f = try Fixture()
        source = f.base.appendingPathComponent("Capsule")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        try Data("first-file".utf8).write(to: source.appendingPathComponent("first.txt"))
        try Data("second-file".utf8).write(to: source.appendingPathComponent("nested/second.txt"))
        try Data().write(to: source.appendingPathComponent(".hidden"))
    }
    func archive() async throws -> FolderArchiveJob {
        let coordinator = coordinator
        let job = try await coordinator.enqueue(source: source, approvedRoot: source)
        try await coordinator.run(job.id)
        return try await coordinator.job(job.id)
    }
    func save(_ job: FolderArchiveJob) throws {
        let url = f.base.appendingPathComponent("catalog/folder-archives/" + job.id.uuidString + ".session.json")
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
    }
}

private final class FolderCleanupObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var triggered = false
    func once(_ condition: Bool, action: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if condition && !triggered { triggered = true; action() }
    }
}

@Test func wholeFolderMovesAndPutsBackWithoutOverwriteOrSilentRemoval() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive(), coordinator = f.coordinator
    try await coordinator.moveToRecovery(job.id)
    #expect(!FileManager.default.fileExists(atPath: f.source.path))
    let staged = try await coordinator.job(job.id)
    #expect(staged.recovery?.stage == .retained)
    #expect(staged.recovery?.retainedBytes == job.totalBytes)
    #expect(try await f.f.catalog.totals().inRecovery == job.totalBytes)
    #expect(try Data(contentsOf: staged.recoveryLocation.appendingPathComponent("first.txt")) == Data("first-file".utf8))
    try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await coordinator.putBackOriginal(job.id) }
    try FileManager.default.removeItem(at: f.source) // Empty conflicting fixture only.
    try await coordinator.putBackOriginal(job.id)
    #expect(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("nested/second.txt").path))
    #expect(try await coordinator.job(job.id).recovery == nil)
    #expect(try await f.f.catalog.totals().inRecovery == 0)
    try await coordinator.moveToRecovery(job.id)
    #expect(try await coordinator.job(job.id).recovery?.stage == .retained)
}

@Test func wholeFolderPermanentCleanupLeavesOtherRecoveryItemsAndRestoresCompleteContents() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    #expect(chmod(f.source.appendingPathComponent("first.txt").path, 0o750) == 0)
    let expectedTime = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: expectedTime], ofItemAtPath: f.source.appendingPathComponent("first.txt").path)
    let job = try await f.archive(), coordinator = f.coordinator
    try await coordinator.moveToRecovery(job.id)
    let unrelated = job.recoveryLocation.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
    try Data("not-managed".utf8).write(to: unrelated)
    try await coordinator.permanentlyRemoveRecovery(job.id)
    let removed = try await coordinator.job(job.id)
    #expect(removed.recovery?.stage == .removed)
    #expect(removed.recovery?.retainedBytes == 0)
    #expect(!FileManager.default.fileExists(atPath: job.recoveryLocation.path))
    #expect(try Data(contentsOf: unrelated) == Data("not-managed".utf8))
    let destination = f.f.base.appendingPathComponent("restore")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let restored = try await coordinator.restore(manifest: #require(job.manifest), destination: destination)
    #expect(try Data(contentsOf: restored.appendingPathComponent("nested/second.txt")) == Data("second-file".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: restored.appendingPathComponent("nested/empty").path).isEmpty)
    var info = stat()
    #expect(lstat(restored.appendingPathComponent("first.txt").path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o700)
    #expect(job.manifest?.metadata?.first(where: { $0.relativePath == "first.txt" })?.mode == 0o750)
    #expect(info.st_mtimespec.tv_sec == 1_700_000_000)
}

@Test func folderCleanupRequiresAllCloudObjectsAndFreshLocalContent() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive(), coordinator = f.coordinator
    await f.f.remote.configure(omit: true)
    await #expect(throws: (any Error).self) { try await coordinator.moveToRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: f.source.path))
    await f.f.remote.configure()
    try await coordinator.moveToRecovery(job.id)
    let retained = job.recoveryLocation.appendingPathComponent("first.txt")
    try Data("changed-recovery".utf8).write(to: retained)
    await #expect(throws: (any Error).self) { try await coordinator.permanentlyRemoveRecovery(job.id) }
    #expect(try Data(contentsOf: retained) == Data("changed-recovery".utf8))
    try await coordinator.putBackOriginal(job.id)
    #expect(try Data(contentsOf: f.source.appendingPathComponent("first.txt")) == Data("changed-recovery".utf8))
}

@Test func folderMetadataAndHardLinksBlockCleanupInsteadOfLosingUnrepresentedData() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let bytes = Data("important directory metadata".utf8)
    let code = bytes.withUnsafeBytes { setxattr(f.source.appendingPathComponent("nested").path, "com.cloudnest.test", $0.baseAddress, $0.count, 0, 0) }
    #expect(code == 0)
    let job = try await f.archive()
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: f.source.path))
    #expect(getxattr(f.source.appendingPathComponent("nested").path, "com.cloudnest.test", nil, 0, 0, 0) > 0)
    #expect(removexattr(f.source.appendingPathComponent("nested").path, "com.cloudnest.test", 0) == 0)
    try FileManager.default.linkItem(at: f.source.appendingPathComponent("first.txt"), to: f.source.appendingPathComponent("hardlink.txt"))
    let linked = try await f.archive()
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(linked.id) }
    #expect(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("hardlink.txt").path))
}

@Test func unexpectedRetainedFolderEntriesNeverGetDeleted() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive(), coordinator = f.coordinator
    try await coordinator.moveToRecovery(job.id)
    let unexpected = job.recoveryLocation.appendingPathComponent("unarchived.txt")
    try Data("unarchived-user-data".utf8).write(to: unexpected)
    await #expect(throws: (any Error).self) { try await coordinator.permanentlyRemoveRecovery(job.id) }
    #expect(try Data(contentsOf: unexpected) == Data("unarchived-user-data".utf8))
    #expect(FileManager.default.fileExists(atPath: job.recoveryLocation.appendingPathComponent("first.txt").path))
    try await coordinator.putBackOriginal(job.id)
    #expect(try Data(contentsOf: f.source.appendingPathComponent("unarchived.txt")) == Data("unarchived-user-data".utf8))
}

@Test func interruptedFolderMoveReconcilesWithoutDeletingAnyMember() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive(), coordinator = f.coordinator
    try await coordinator.moveToRecovery(job.id)
    var interrupted = try await coordinator.job(job.id)
    interrupted.recovery?.stage = .moving; try f.save(interrupted)
    try await coordinator.reconcileRecovery()
    #expect(try await coordinator.job(job.id).recovery?.stage == .retained)
    #expect(FileManager.default.fileExists(atPath: job.recoveryLocation.appendingPathComponent("first.txt").path))
}

@Test func interruptedFolderPermanentCleanupNeedsNewApprovalAndCannotPutBackIncompleteTree() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let observer = FolderCleanupObserver()
    let coordinator = FolderArchiveCoordinator(catalog: f.f.catalog, remote: f.f.remote, secrets: f.f.secrets, onFolderChanged: { job in
        observer.once(job.recovery?.stage == .removing && job.recovery?.removedFileCount == 1) { withUnsafeCurrentTask { $0?.cancel() } }
    })
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    try await coordinator.run(job.id); try await coordinator.moveToRecovery(job.id)
    let task = Task { try await coordinator.permanentlyRemoveRecovery(job.id) }
    await #expect(throws: (any Error).self) { try await task.value }
    let interrupted = try await coordinator.job(job.id)
    #expect(interrupted.recovery?.stage == .removing)
    #expect(interrupted.recovery?.removedFiles.count == 1)
    let restoredCoordinator = f.coordinator
    try await restoredCoordinator.reconcileRecovery()
    #expect(try await restoredCoordinator.job(job.id).recovery?.removedFiles.count == 1)
    #expect(FileManager.default.fileExists(atPath: job.recoveryLocation.appendingPathComponent("first.txt").path))
    await #expect(throws: (any Error).self) { try await restoredCoordinator.putBackOriginal(job.id) }
    try await restoredCoordinator.permanentlyRemoveRecovery(job.id)
    #expect(try await restoredCoordinator.job(job.id).recovery?.stage == .removed)
}

@Test func folderHealthChecksRootAndEveryChildAndProtectedPolicyRemainsEnforced() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive()
    #expect(await f.coordinator.health(job.id).status == .healthy)
    let manifest = try #require(job.manifest)
    await f.f.remote.removeFolderObject(manifest.files.first!.manifest.driveFileID)
    #expect(await f.coordinator.health(job.id).status == .missing)
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(job.id) }
    let next = try await f.archive()
    let protected = FolderArchiveCoordinator(catalog: f.f.catalog, remote: f.f.remote, secrets: f.f.secrets, safety: FileSafety(protectedRoots: [f.source.appendingPathComponent("nested")]))
    await #expect(throws: (any Error).self) { try await protected.moveToRecovery(next.id) }
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func legacyFolderManifestRestoresButCannotAuthorizeWholeFolderCleanup() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    var job = try await f.archive()
    let original = try #require(job.manifest)
    let legacy = FolderArchiveManifest(id: original.id, folderName: original.folderName, createdAt: original.createdAt, directories: original.directories, files: original.files)
    job.manifest = legacy; try f.save(job)
    await f.f.remote.replaceFolderObject(job.remoteManifestID!, data: try legacy.encoded())
    #expect(await f.coordinator.health(job.id).status == .healthy)
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(job.id) }
    let destination = f.f.base.appendingPathComponent("legacy-restore")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    _ = try await f.coordinator.restore(manifest: legacy, destination: destination)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Capsule/nested/second.txt").path))
}

@Test func recoveredFolderCatalogIsPagedAndNeverCreatesCleanupAuthority() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive(), manifest = try #require(job.manifest)
    let recovered = RecoveredFolderArchive(manifest: manifest, manifestID: job.remoteManifestID!)
    #expect(try await f.f.catalog.saveRecoveredFolder(recovered))
    #expect(try await !f.f.catalog.saveRecoveredFolder(recovered))
    #expect(try await f.f.catalog.recoveredFolderCount(query: "Capsule") == 1)
    let list = try await f.f.catalog.recoveredFolders(query: "Capsule", limit: 1)
    #expect(list.count == 1 && list.first?.fileCount == 3 && list.first?.totalBytes == job.totalBytes)
    #expect(try await f.f.catalog.recoveredFolders(offset: 1).isEmpty)
    #expect(try await f.f.catalog.recoveredFolder(job.id).manifest.encoded() == manifest.encoded())
    let conflict = FolderArchiveManifest(id: manifest.id, folderName: "Conflict", createdAt: manifest.createdAt, directories: manifest.directories, files: manifest.files, metadata: manifest.metadata)
    await #expect(throws: NestError.self) { try await f.f.catalog.saveRecoveredFolder(RecoveredFolderArchive(manifest: conflict, manifestID: "conflicting-root")) }
    let emptyCatalog = try Catalog(directory: f.f.base.appendingPathComponent("rebuilt-catalog"))
    #expect(try await emptyCatalog.saveRecoveredFolder(recovered))
    #expect(try await emptyCatalog.jobs().isEmpty)
    #expect(try await emptyCatalog.recoveryJobCount() == 0)
}

@Test func folderMetadataManifestRejectsMissingDuplicateAndMalformedPermissionEvidence() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive(), manifest = try #require(job.manifest), metadata = try #require(manifest.metadata)
    func bad(_ entries: [FolderEntryMetadata]) -> FolderArchiveManifest {
        FolderArchiveManifest(id: manifest.id, folderName: manifest.folderName, createdAt: manifest.createdAt, directories: manifest.directories, files: manifest.files, metadata: entries)
    }
    #expect(throws: (any Error).self) { try bad(Array(metadata.dropLast())).validate() }
    #expect(throws: (any Error).self) { try bad(metadata + [metadata[0]]).validate() }
    let invalid = FolderEntryMetadata(relativePath: "", isDirectory: true, mode: 0o7777, modifiedSeconds: 0, modifiedNanos: 0, provenance: nil)
    #expect(throws: (any Error).self) { try bad([invalid] + Array(metadata.dropFirst())).validate() }
}

@Test func explicitACLOnFolderMemberBlocksCleanupWhileSuccessfulAbsenceQueryAllowsOrdinaryFiles() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let path = f.source.appendingPathComponent("first.txt")
    let change = Process(); change.executableURL = URL(fileURLWithPath: "/bin/chmod")
    change.arguments = ["+a", "user:\(NSUserName()) allow read", path.path]
    change.standardOutput = FileHandle.nullDevice; change.standardError = FileHandle.nullDevice
    try change.run(); change.waitUntilExit(); #expect(change.terminationStatus == 0)
    let job = try await f.archive()
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: path.path))
}

@Test func unknownDataInjectedAfterDeletionStartsIsRetainedAndNeverRecursivelyErased() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let observer = FolderCleanupObserver()
    let coordinator = FolderArchiveCoordinator(catalog: f.f.catalog, remote: f.f.remote, secrets: f.f.secrets, onFolderChanged: { job in
        observer.once(job.recovery?.stage == .removing && job.recovery?.removedFileCount == 1) {
            try? Data("unarchived-during-cleanup".utf8).write(to: job.recoveryLocation.appendingPathComponent("unexpected.txt"))
        }
    })
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    try await coordinator.run(job.id); try await coordinator.moveToRecovery(job.id)
    await #expect(throws: (any Error).self) { try await coordinator.permanentlyRemoveRecovery(job.id) }
    #expect(try Data(contentsOf: job.recoveryLocation.appendingPathComponent("unexpected.txt")) == Data("unarchived-during-cleanup".utf8))
    #expect(try await coordinator.job(job.id).recovery?.stage != .removed)
}

@Test func pendingIntentAfterMemberUnlinkResumesOnlyOnFreshExplicitCall() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive(), coordinator = f.coordinator
    try await coordinator.moveToRecovery(job.id)
    var interrupted = try await coordinator.job(job.id)
    let first = try #require(job.manifest?.files.first?.relativePath)
    interrupted.recovery?.stage = .removing; interrupted.recovery?.pendingRemoval = first
    try f.save(interrupted)
    try FileManager.default.removeItem(at: job.recoveryLocation.appendingPathComponent(first)) // Simulates the test-owned approved unlink before durable acknowledgement.
    try await f.coordinator.permanentlyRemoveRecovery(job.id)
    #expect(try await coordinator.job(job.id).recovery?.stage == .removed)
}

@Test func interruptedFolderPutBackReconcilesToPresentOriginalWithoutDeletion() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive(), coordinator = f.coordinator
    try await coordinator.moveToRecovery(job.id)
    var intent = try await coordinator.job(job.id)
    intent.recovery?.stage = .puttingBack; try f.save(intent)
    #expect(rename(job.recoveryLocation.path, f.source.path) == 0) // Test-owned completed rename before acknowledgement.
    try await f.coordinator.reconcileRecovery()
    #expect(try await coordinator.job(job.id).recovery == nil)
    #expect(try Data(contentsOf: f.source.appendingPathComponent("first.txt")) == Data("first-file".utf8))
}

@Test func folderOperationLeaseBlocksAllCleanupMutations() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive()
    let lease = try OperationLease.acquire(catalogDirectory: f.f.base.appendingPathComponent("catalog"), jobID: job.id)
    defer { withExtendedLifetime(lease) {} }
    await #expect(throws: NestError.self) { try await f.coordinator.moveToRecovery(job.id) }
    await #expect(throws: NestError.self) { try await f.coordinator.permanentlyRemoveRecovery(job.id) }
    await #expect(throws: NestError.self) { try await f.coordinator.putBackOriginal(job.id) }
    #expect(try await f.coordinator.job(job.id).recovery == nil)
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func recoveredFolderHealthVerifiesCanonicalRootAndAllEmbeddedFileReferences() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let job = try await f.archive()
    let archive = RecoveredFolderArchive(manifest: try #require(job.manifest), manifestID: try #require(job.remoteManifestID))
    let checker = FolderArchiveHealthChecker(remote: f.f.remote)
    #expect(await checker.check(archive).status == .healthy)
    await f.f.remote.replaceFolderObject(archive.manifest.files.first!.manifest.driveFileID, data: Data("corrupt-child".utf8))
    #expect(await checker.check(archive).status == .mismatch)
    let next = try await f.archive()
    let other = RecoveredFolderArchive(manifest: try #require(next.manifest), manifestID: try #require(next.remoteManifestID))
    await f.f.remote.removeFolderObject(other.manifestID)
    #expect(await checker.check(other).status == .missing)
}

private func removePrivateDirectoryMetadataForLegacyQueue(_ f: FolderCleanupFixture, job: FolderArchiveJob) throws {
    let path = f.f.base.appendingPathComponent("catalog/folder-archives/" + job.id.uuidString + ".session.json")
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
    var directories = value["directories"] as! [[String: Any]]
    for index in directories.indices { directories[index].removeValue(forKey: "metadata") }
    value["directories"] = directories
    try JSONSerialization.data(withJSONObject: value).write(to: path, options: .atomic)
}

@Test func legacyQueuedFolderResumesWithNewEvidenceOnlyAfterOriginalIdentityAndHashValidation() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let queued = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    try removePrivateDirectoryMetadataForLegacyQueue(f, job: queued)
    try await coordinator.run(queued.id)
    let complete = try await coordinator.job(queued.id)
    #expect(complete.state == .verified && complete.manifest?.metadata != nil)
    try await coordinator.moveToRecovery(queued.id)
    #expect(try await coordinator.job(queued.id).recovery?.stage == .retained)
}

@Test func legacyUploadedRootResumesWithoutOverwritingItsRemoteManifestFormat() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    var job = try await f.archive()
    let original = try #require(job.manifest)
    let legacy = FolderArchiveManifest(id: original.id, folderName: original.folderName, createdAt: original.createdAt, directories: original.directories, files: original.files)
    job.manifest = legacy; job.state = .uploaded
    try removePrivateDirectoryMetadataForLegacyQueue(f, job: job)
    await f.f.remote.replaceFolderObject(job.remoteManifestID!, data: try legacy.encoded())
    try await f.coordinator.run(job.id)
    let complete = try await f.coordinator.job(job.id)
    #expect(complete.state == .verified)
    #expect(complete.remoteManifestID == job.remoteManifestID && complete.manifest?.metadata == nil)
    #expect(try complete.manifest?.encoded() == legacy.encoded())
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(job.id) }
}

@Test func folderRecoveryHeadersFindOldRecordsAndSummariesNeverCarryLargeRemovalJournals() async throws {
    let f = try FolderCleanupFixture(); defer { f.f.clean() }
    var seed = try await f.archive()
    seed.recovery = FolderLocalRecovery(stage: .removing, retainedBytes: 42, removedFiles: (0..<10_000).map { "removed-\($0).bin" })
    let summary = seed.summary
    #expect(summary.recovery?.removedFiles.isEmpty == true)
    #expect(summary.recovery?.removedFileCount == 10_000)
    #expect(summary.summary.recovery?.removedFileCount == 10_000)
    #expect(summary.recovery?.canPutBack == false)
    #expect(try JSONEncoder().encode(summary).count < 2048)
    try await f.f.catalog.saveFolderRecoveryTotals(seed)
    let oldID = seed.id
    for _ in 0..<501 {
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as! [String: Any]
        value["id"] = UUID().uuidString
        var copy = try JSONDecoder().decode(FolderArchiveJob.self, from: JSONSerialization.data(withJSONObject: value))
        copy.recovery = FolderLocalRecovery(stage: .retained, retainedBytes: 42)
        try await f.f.catalog.saveFolderRecoveryTotals(copy)
    }
    #expect(try await f.f.catalog.folderRecoveryRecordCount() == 502)
    let first = try await f.f.catalog.folderRecoveryRecords(limit: 1000)
    #expect(first.count == 500 && !first.contains(where: { $0.id == oldID }))
    let tail = try await f.f.catalog.folderRecoveryRecords(limit: 10, offset: 500)
    #expect(tail.count == 2 && tail.contains(where: { $0.id == oldID && !$0.canPutBack }))
    #expect(try JSONEncoder().encode(tail).count < 2048)
}
