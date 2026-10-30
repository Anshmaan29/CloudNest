import Testing
import Foundation
import CryptoKit
import Darwin
@testable import CloudNestCore

private actor FolderTestRemote: ArchiveRemote {
    let base = TestRemote()
    var folderIDs = Set<String>(), folderSessions = Set<URL>()
    var interruptFolder = false
    var corruptFolderChecksum = false
    var mutateDuringRestoreAt: URL?
    var injectUnexpected = false
    var downloadCalls = 0
    func configure(interruptFolder: Bool = false, corruptFolderChecksum: Bool = false, mutateDuringRestoreAt: URL? = nil, injectUnexpected: Bool = false) {
        self.interruptFolder = interruptFolder; self.corruptFolderChecksum = corruptFolderChecksum
        self.mutateDuringRestoreAt = mutateDuringRestoreAt; self.injectUnexpected = injectUnexpected; downloadCalls = 0
    }
    func allocateID() async -> String { await base.allocateID() }
    func begin(id: String, name: String, size: Int64, jobID: UUID) async -> URL {
        let session = await base.begin(id: id, name: name, size: size, jobID: jobID)
        if name.hasSuffix(".cloudnest-folder.json") { folderIDs.insert(id); folderSessions.insert(session) }
        return session
    }
    func status(session: URL, total: Int64) async throws -> UploadProgress { try await base.status(session: session, total: total) }
    func send(session: URL, data: Data, offset: Int64, total: Int64) async throws -> UploadProgress {
        let result = try await base.send(session: session, data: data, offset: offset, total: total)
        if interruptFolder && folderSessions.contains(session) { interruptFolder = false; throw NestError.http(503) }
        return result
    }
    func metadata(id: String) async throws -> RemoteFile {
        let info = try await base.metadata(id: id)
        if corruptFolderChecksum && folderIDs.contains(id) { return RemoteFile(id: info.id, size: info.size, sha256Checksum: String(repeating: "0", count: 64)) }
        return info
    }
    func storeManifest(_ manifest: ArchiveManifest) async throws -> String { try await base.storeManifest(manifest) }
    func download(id: String, into destination: FileHandle, maximumBytes: Int64) async throws {
        downloadCalls += 1
        if downloadCalls == 2, let root = mutateDuringRestoreAt,
           let stage = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix(".cloudnest-folder-restore-") }) {
            let filename = injectUnexpected ? "unexpected.txt" : ".hidden"
            try Data("changed while another file downloads".utf8).write(to: stage.appendingPathComponent(filename))
        }
        try await base.download(id: id, into: destination, maximumBytes: maximumBytes)
    }
}

private struct FolderFixture {
    let f: Fixture
    let source: URL
    let remote = FolderTestRemote()
    var coordinator: FolderArchiveCoordinator { FolderArchiveCoordinator(catalog: f.catalog, remote: remote, secrets: f.secrets) }
    init() throws {
        f = try Fixture()
        source = f.base.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested/deeper/empty"), withIntermediateDirectories: true)
        try Data("top-level".utf8).write(to: source.appendingPathComponent("top.txt"))
        try Data("nested-content".utf8).write(to: source.appendingPathComponent("nested/deeper/note.txt"))
        try Data().write(to: source.appendingPathComponent(".hidden"))
    }
    func destination() throws -> URL {
        let url = f.base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

@Test func nestedFolderArchiveRestoresEmptyDirectoriesAndHiddenFiles() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    #expect(job.totalFiles == 3)
    #expect(job.totalBytes == 23)
    try await coordinator.run(job.id)
    let complete = try await coordinator.job(job.id)
    #expect(complete.state == .verified)
    #expect(complete.completedFiles == 3)
    let manifest = try #require(complete.manifest)
    let savedManifest = try FolderArchiveManifest.read(from: await coordinator.manifestURL(for: job.id))
    #expect(try savedManifest.encoded() == manifest.encoded())
    #expect(manifest.directories.contains("nested/deeper/empty"))
    let destination = try f.destination()
    let restored = try await coordinator.restore(manifest: manifest, destination: destination)
    #expect(try Data(contentsOf: restored.appendingPathComponent("top.txt")) == Data("top-level".utf8))
    #expect(try Data(contentsOf: restored.appendingPathComponent("nested/deeper/note.txt")) == Data("nested-content".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: restored.appendingPathComponent("nested/deeper/empty").path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent(".hidden").path))
    #expect(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("top.txt").path))
    await #expect(throws: (any Error).self) { try await coordinator.restore(manifest: manifest, destination: destination) }
    #expect(try await coordinator.jobs().count == 1)
}

@Test func folderInterruptionResumesAfterReopeningCatalog() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    await f.remote.base.configure(interrupt: true)
    await #expect(throws: (any Error).self) { try await coordinator.run(job.id) }
    #expect(try await coordinator.job(job.id).state != .verified)
    let reopenedCatalog = try Catalog(directory: f.f.base.appendingPathComponent("catalog"))
    let reopened = FolderArchiveCoordinator(catalog: reopenedCatalog, remote: f.remote, secrets: f.f.secrets)
    try await reopened.run(job.id)
    #expect(try await reopened.job(job.id).state == .verified)
    // Three data objects, three independently verified file manifests, one root manifest.
    #expect(await f.remote.base.objects.count == 7)
}

@Test func folderLostFinalManifestAcknowledgementDoesNotDuplicateRoot() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    await f.remote.configure(interruptFolder: true)
    await #expect(throws: (any Error).self) { try await coordinator.run(job.id) }
    let interrupted = try await coordinator.job(job.id)
    #expect(interrupted.completedFiles == 3)
    #expect(interrupted.remoteManifestID != nil)
    try await f.coordinator.run(job.id)
    #expect(try await coordinator.job(job.id).state == .verified)
    #expect(await f.remote.base.objects.count == 7)
}

@Test func folderMissingOrCorruptRootVerificationNeverCompletes() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    await f.remote.configure(corruptFolderChecksum: true)
    await #expect(throws: (any Error).self) { try await coordinator.run(job.id) }
    #expect(try await coordinator.job(job.id).state != .verified)
    #expect(try Data(contentsOf: f.source.appendingPathComponent("top.txt")) == Data("top-level".utf8))
}

@Test func addedFolderMemberAndModifiedSourceBothRefuseResume() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    try Data("extra".utf8).write(to: f.source.appendingPathComponent("added.txt"))
    await #expect(throws: (any Error).self) { try await coordinator.run(job.id) }
    #expect(await f.remote.base.sentOffsets.isEmpty)
    let newJob = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    try Data("changed".utf8).write(to: f.source.appendingPathComponent("top.txt"))
    await #expect(throws: (any Error).self) { try await coordinator.run(newJob.id) }
    #expect(await f.remote.base.sentOffsets.isEmpty)
}

@Test func folderRefusesSymlinksProtectedMembersAndDatabasesBeforeUploading() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let link = f.source.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.f.source)
    await #expect(throws: (any Error).self) { try await coordinator.enqueue(source: f.source, approvedRoot: f.source) }
    try FileManager.default.removeItem(at: link)
    let db = f.source.appendingPathComponent("live.sqlite")
    try Data("db".utf8).write(to: db)
    await #expect(throws: (any Error).self) { try await coordinator.enqueue(source: f.source, approvedRoot: f.source) }
    try FileManager.default.removeItem(at: db)
    let protected = f.source.appendingPathComponent("nested")
    let guarded = FolderArchiveCoordinator(catalog: f.f.catalog, remote: f.remote, secrets: f.f.secrets, safety: FileSafety(protectedRoots: [protected]))
    await #expect(throws: (any Error).self) { try await guarded.enqueue(source: f.source, approvedRoot: f.source) }
    #expect(await f.remote.base.objects.isEmpty)
}

@Test func folderCorruptRestoreNeverInstallsPartialRoot() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    try await coordinator.run(job.id)
    let manifest = try #require(try await coordinator.job(job.id).manifest)
    await f.remote.base.configure(download: true)
    let destination = try f.destination()
    await #expect(throws: (any Error).self) { try await coordinator.restore(manifest: manifest, destination: destination) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
}

@Test func emptyFolderArchivesAndRestores() async throws {
    let f = try Fixture(); defer { f.clean() }
    let source = f.base.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let coordinator = FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets)
    let job = try await coordinator.enqueue(source: source, approvedRoot: source)
    #expect(job.totalFiles == 0)
    try await coordinator.run(job.id)
    let manifest = try #require(try await coordinator.job(job.id).manifest)
    let destination = f.base.appendingPathComponent("restore-empty")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let result = try await coordinator.restore(manifest: manifest, destination: destination)
    #expect(try FileManager.default.contentsOfDirectory(atPath: result.path).isEmpty)
}

@Test func folderManifestRejectsTraversalAliasesMissingParentsAndFileAncestors() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    let file = ArchiveManifest(job: job, driveFileID: "test-file")
    func manifest(_ dirs: [String], _ files: [FolderArchiveFile] = [], name: String = "Folder") -> FolderArchiveManifest {
        FolderArchiveManifest(id: UUID(), folderName: name, createdAt: Date(), directories: dirs, files: files)
    }
    #expect(throws: (any Error).self) { try manifest(["../escape"]).validate() }
    #expect(throws: (any Error).self) { try manifest(["Case", "case"]).validate() }
    #expect(throws: (any Error).self) { try manifest(["café", "cafe\u{301}"]).validate() }
    #expect(throws: (any Error).self) { try manifest(["nested/deep"]).validate() }
    #expect(throws: (any Error).self) { try manifest([], name: "../Folder").validate() }
    #expect(throws: (any Error).self) { try manifest(["folder\\escape"]).validate() }
    #expect(throws: (any Error).self) { try manifest([], [FolderArchiveFile(relativePath: "a/" + file.fileName, manifest: file)]).validate() }
    #expect(throws: (any Error).self) { try manifest([file.fileName], [FolderArchiveFile(relativePath: file.fileName, manifest: file)]).validate() }
}

@Test func folderCancellationPersistsPauseWithoutDeletingSource() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    let task = Task { try await coordinator.run(job.id) }
    task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(try await coordinator.job(job.id).state != .verified)
    #expect(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("top.txt").path))
    try await coordinator.run(job.id)
    #expect(try await coordinator.job(job.id).state == .verified)
}


@Test func folderRestoreRechecksEarlierFilesAndRetainsUnexpectedStagedData() async throws {
    for inject in [false, true] {
        let f = try FolderFixture(); defer { f.f.clean() }
        let coordinator = f.coordinator
        let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
        try await coordinator.run(job.id)
        let manifest = try #require(try await coordinator.job(job.id).manifest)
        let destination = try f.destination()
        await f.remote.configure(mutateDuringRestoreAt: destination, injectUnexpected: inject)
        await #expect(throws: (any Error).self) { try await coordinator.restore(manifest: manifest, destination: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Folder").path))
        let stage = try #require(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).first)
        let retained = stage.appendingPathComponent(inject ? "unexpected.txt" : ".hidden")
        #expect(try Data(contentsOf: retained) == Data("changed while another file downloads".utf8))
    }
}

@Test func folderJobsReturnBoundedSummariesAndMembersCannotBeReclaimed() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let first = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    let second = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    try await coordinator.run(first.id)
    let listed = try await coordinator.jobs(limit: 1)
    #expect(listed.count == 1)
    #expect(listed[0].manifest == nil)
    #expect(try await coordinator.jobs(limit: 1, offset: 1).count == 1)
    #expect(try await coordinator.jobs(limit: 1, offset: 100).isEmpty)
    #expect(try await coordinator.job(second.id).state == .queued)
    let members = try await f.f.catalog.jobs().filter { $0.folderArchiveID == first.id }
    #expect(members.count == 3)
    let fileCoordinator = ArchiveCoordinator(catalog: f.f.catalog, remote: f.remote, secrets: f.f.secrets)
    await #expect(throws: (any Error).self) { try await fileCoordinator.moveToRecovery(members[0].id) }
}

@Test func folderArchiveHandlesMoreThanCatalogDisplayPageOfMembers() async throws {
    let f = try Fixture(); defer { f.clean() }
    let source = f.base.appendingPathComponent("many-files")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    for index in 0..<510 { try Data([UInt8(index % 251)]).write(to: source.appendingPathComponent("file-\(index).bin")) }
    let coordinator = FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets)
    let job = try await coordinator.enqueue(source: source, approvedRoot: source)
    #expect(job.totalFiles == 510)
    try await coordinator.run(job.id)
    let complete = try await coordinator.job(job.id)
    #expect(complete.state == .verified)
    #expect(complete.manifest?.files.count == 510)
    #expect(try await f.catalog.jobs().count == 500)
}


@Test func folderRestoreRejectsProtectedFinalNameBeforeWriting() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    try await coordinator.run(job.id)
    let manifest = try #require(try await coordinator.job(job.id).manifest)
    let destination = try f.destination()
    let blocked = destination.appendingPathComponent(manifest.folderName)
    let guarded = FolderArchiveCoordinator(catalog: f.f.catalog, remote: f.remote, secrets: f.f.secrets, safety: FileSafety(protectedRoots: [blocked]))
    await #expect(throws: (any Error).self) { try await guarded.restore(manifest: manifest, destination: destination) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    let databaseName = FolderArchiveManifest(id: manifest.id, folderName: "active.sqlite", createdAt: manifest.createdAt, directories: manifest.directories, files: manifest.files)
    await #expect(throws: (any Error).self) { try await coordinator.restore(manifest: databaseName, destination: destination) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
}

@Test func competingFolderCoordinatorsRespectProcessLease() async throws {
    let f = try FolderFixture(); defer { f.f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.source)
    let lease = try OperationLease.acquire(catalogDirectory: f.f.base.appendingPathComponent("catalog"), jobID: job.id)
    defer { withExtendedLifetime(lease) {} }
    await #expect(throws: NestError.self) { try await f.coordinator.run(job.id) }
    #expect(try await coordinator.job(job.id).state == .queued)
    #expect(await f.remote.base.objects.isEmpty)
    #expect(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("top.txt").path))
}
