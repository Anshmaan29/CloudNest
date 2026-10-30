import Foundation
import CryptoKit
import Darwin

public actor ArchiveCoordinator {
    private let catalog: Catalog
    private let remote: any ArchiveRemote
    private let secrets: any SecretStore
    private let safety: FileSafety
    private let onJobChanged: @Sendable (ArchiveJob) async -> Void
    private var running = false
    public static let chunkBytes = 8 * 1024 * 1024
    public init(catalog: Catalog, remote: any ArchiveRemote, secrets: any SecretStore = KeychainStore(), safety: FileSafety = FileSafety(), onJobChanged: @escaping @Sendable (ArchiveJob) async -> Void = { _ in }) {
        self.catalog = catalog; self.remote = remote; self.secrets = secrets; self.safety = safety
        self.onJobChanged = onJobChanged
    }
    private func persist(_ job: ArchiveJob) async throws { try await catalog.save(job); await onJobChanged(job) }
    public func enqueue(source: URL, approvedRoot: URL, folderArchiveID: UUID? = nil) async throws -> ArchiveJob {
        let snapshot = try safety.snapshot(source, root: approvedRoot)
        var job = ArchiveJob(source: source, approvedRoot: approvedRoot, snapshot: snapshot)
        job.folderArchiveID = folderArchiveID
        try await persist(job)
        return job
    }
    public func run(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }
        running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id)
        defer { withExtendedLifetime(lease) {} }
        var job = try await catalog.job(id)
        if job.state == .verified { return }
        let sessionKey = "upload-" + id.uuidString
        do {
            guard try safety.snapshot(job.source, root: job.approvedRoot) == job.snapshot else { throw NestError.sourceChanged }
            if job.remoteID == nil { job.remoteID = try await remote.allocateID(); try await persist(job) }
            guard let remoteID = job.remoteID else { throw NestError.invalidManifest }
            // The final acknowledgement can be lost. Check the pre-generated ID before sending again.
            var existing: RemoteFile?
            do { existing = try await remote.metadata(id: remoteID) } catch NestError.http(404) { /* Not uploaded yet. */ }
            if let existing {
                guard existing.matches(job.snapshot) else { throw NestError.verificationFailed }
                job.state = .uploaded; job.offset = job.snapshot.identity.size; try await persist(job)
            } else {
                var sessionURL: URL
                if let stored = try await secrets.read(sessionKey), let url = URL(string: String(decoding: stored, as: UTF8.self)) {
                    sessionURL = url
                    do {
                        let progress = try await remote.status(session: url, total: job.snapshot.identity.size)
                        job.offset = progress.offset
                        if progress.complete { job.state = .uploaded }
                    } catch NestError.http(404) {
                        try await secrets.remove(sessionKey)
                        job.offset = 0
                        sessionURL = try await remote.begin(id: remoteID, name: job.source.lastPathComponent, size: job.snapshot.identity.size, jobID: id)
                        try await secrets.write(sessionKey, value: Data(sessionURL.absoluteString.utf8))
                    }
                } else {
                    job.offset = 0
                    sessionURL = try await remote.begin(id: remoteID, name: job.source.lastPathComponent, size: job.snapshot.identity.size, jobID: id)
                    try await secrets.write(sessionKey, value: Data(sessionURL.absoluteString.utf8))
                }
                if job.state != .uploaded {
                    job.state = .uploading; try await persist(job)
                    let file = try safety.openSource(job.source, root: job.approvedRoot)
                    let fd = file.fileDescriptor; defer { try? file.close() }
                    var info = stat()
                    guard fstat(fd, &info) == 0, FileSafety.identity(info) == job.snapshot.identity else { throw NestError.sourceChanged }
                    repeat {
                        try Task.checkCancellation()
                        try file.seek(toOffset: UInt64(job.offset))
                        let count = Int(min(Int64(Self.chunkBytes), job.snapshot.identity.size - job.offset))
                        let data = try autoreleasepool { try file.read(upToCount: count) ?? Data() }
                        guard data.count == count else { throw NestError.sourceChanged }
                        let progress = try await remote.send(session: sessionURL, data: data, offset: job.offset, total: job.snapshot.identity.size)
                        guard progress.offset >= job.offset, progress.offset <= job.snapshot.identity.size,
                              progress.offset > job.offset || progress.complete else { throw NestError.invalidResponse }
                        job.offset = progress.offset
                        if progress.complete { job.state = .uploaded }
                        try await persist(job)
                    } while job.state != .uploaded
                }
            }
            let metadata = try await remote.metadata(id: remoteID)
            guard metadata.matches(job.snapshot) else { throw NestError.verificationFailed }
            guard try safety.snapshot(job.source, root: job.approvedRoot) == job.snapshot else { throw NestError.sourceChanged }
            let manifest = ArchiveManifest(job: job, driveFileID: remoteID)
            let manifestURL = try await catalog.writeManifest(manifest)
            if job.manifestID == nil { job.manifestID = try await remote.storeManifest(manifest); try await persist(job) }
            let manifestData = try Data(contentsOf: manifestURL)
            let digest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
            let manifestMetadata = try await remote.metadata(id: job.manifestID!)
            guard manifestMetadata.trashed == false, manifestMetadata.sha256Checksum == digest,
                  Int64(manifestMetadata.size ?? "") == Int64(manifestData.count) else { throw NestError.verificationFailed }
            guard try safety.snapshot(job.source, root: job.approvedRoot) == job.snapshot else { throw NestError.sourceChanged }
            job.state = .verified; job.lastError = nil; try await persist(job)
            try await secrets.remove(sessionKey)
        } catch {
            job.lastError = (error as? NestError)?.localizedDescription ?? (error is CancellationError ? "Paused." : "Transfer interrupted. Retry to resume.")
            try await persist(job)
            throw error
        }
    }
    public func restore(manifest: ArchiveManifest, destination: URL) async throws -> URL {
        try manifest.validate()
        try safety.validate(destination, root: destination)
        let directoryFD = try FileSafety.openDirectory(destination); defer { close(directoryFD) }
        let target = destination.appendingPathComponent(manifest.fileName)
        try safety.validateDestination(target, root: destination)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NestError.conflict }
        let stageName = ".cloudnest-restore-" + UUID().uuidString
        guard mkdirat(directoryFD, stageName, 0o700) == 0 else { throw NestError.unsafePath("cannot create restore staging folder") }
        defer { unlinkat(directoryFD, stageName, AT_REMOVEDIR) }
        let stageFD = openat(directoryFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw NestError.unsafePath("staging folder unavailable") }
        defer { close(stageFD) }
        defer { unlinkat(stageFD, "payload", 0) }
        let metadata = try await remote.metadata(id: manifest.driveFileID)
        guard metadata.trashed == false, Int64(metadata.size ?? "") == manifest.size,
              metadata.sha256Checksum == manifest.sha256 else { throw NestError.verificationFailed }
        let payloadFD = openat(stageFD, "payload", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard payloadFD >= 0 else { throw NestError.unsafePath("cannot write restore") }
        let output = FileHandle(fileDescriptor: payloadFD, closeOnDealloc: true); defer { try? output.close() }
        try await remote.download(id: manifest.driveFileID, into: output, maximumBytes: manifest.size)
        try output.synchronize(); try output.seek(toOffset: 0)
        let restored = try FileSafety.snapshot(output)
        guard restored.sha256 == manifest.sha256, restored.identity.size == manifest.size else { throw NestError.verificationFailed }
        try safety.validate(destination, root: destination)
        let currentFD = try FileSafety.openDirectory(destination); defer { close(currentFD) }
        var originalInfo = stat(), currentInfo = stat()
        guard fstat(directoryFD, &originalInfo) == 0, fstat(currentFD, &currentInfo) == 0,
              originalInfo.st_dev == currentInfo.st_dev, originalInfo.st_ino == currentInfo.st_ino else { throw NestError.unsafePath("destination moved") }
        try safety.validateDestination(target, root: destination)
        // Anchored descriptors prevent path swaps. linkat is atomic and never overwrites.
        guard linkat(stageFD, "payload", directoryFD, manifest.fileName, 0) == 0 else { if errno == EEXIST { throw NestError.conflict }; throw NestError.unsafePath("could not install restored file") }
        return target
    }

    private func verifyArchive(_ job: ArchiveJob) async throws {
        guard job.state == .verified, let remoteID = job.remoteID, let manifestID = job.manifestID else { throw NestError.verificationFailed }
        guard try await remote.metadata(id: remoteID).matches(job.snapshot) else { throw NestError.verificationFailed }
        let data = try ArchiveManifest(job: job, driveFileID: remoteID).encoded()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let metadata = try await remote.metadata(id: manifestID)
        guard metadata.trashed == false, metadata.sha256Checksum == digest,
              Int64(metadata.size ?? "") == Int64(data.count) else { throw NestError.verificationFailed }
    }

    /// Call only after an explicit local user approval. This retains all bytes.
    public func moveToRecovery(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id)
        defer { withExtendedLifetime(lease) {} }
        var job = try await catalog.job(id)
        guard job.recovery == nil else { throw NestError.conflict }
        guard job.folderArchiveID == nil else { throw NestError.unsafePath("folder archive members retain their originals; folder-wide cleanup is not enabled") }
        try await verifyArchive(job)
        guard try safety.snapshot(job.source, root: job.approvedRoot) == job.snapshot else { throw NestError.sourceChanged }
        try FileSafety.requireUnused(job.source)
        let sourceHandle = try safety.openSource(job.source, root: job.approvedRoot)
        defer { try? sourceHandle.close() }
        try FileSafety.requireArchivedMetadata(descriptor: sourceHandle.fileDescriptor, provenance: job.snapshot.provenance)
        let sourceFD = try FileSafety.openDirectory(job.source.deletingLastPathComponent()); defer { close(sourceFD) }
        let recoveryFD = try RecoveryFiles.openFolder(job, create: true); defer { close(recoveryFD) }
        job.recovery = LocalRecovery(stage: .moving); try await persist(job)
        guard renameatx_np(sourceFD, job.source.lastPathComponent, recoveryFD, RecoveryFiles.name(job), UInt32(RENAME_EXCL)) == 0 else {
            job.recovery = nil; try await persist(job); throw NestError.conflict
        }
        // A change racing with the move is preserved in recovery and never purged.
        let moved = try RecoveryFiles.snapshot(job, directoryFD: recoveryFD)
        if !RecoveryFiles.matchesContent(moved, job) {
            job.recovery = LocalRecovery(stage: .needsReview, retainedBytes: moved.identity.size)
            job.lastError = "Source changed while moving. Its current data is retained in CloudNest recovery; permanent removal is blocked."
            try await persist(job); throw NestError.sourceChanged
        }
        job.recovery = LocalRecovery(stage: .retained, retainedBytes: moved.identity.size)
        job.lastError = nil; try await persist(job)
    }

    /// Separate irreversible action. The UI must ask for approval every time.
    public func permanentlyRemoveRecovery(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id)
        defer { withExtendedLifetime(lease) {} }
        var job = try await catalog.job(id)
        guard job.recovery?.stage == .retained || job.recovery?.stage == .removing else { throw NestError.verificationFailed }
        try await verifyArchive(job)
        try safety.validate(job.approvedRoot, root: job.approvedRoot)
        let directoryFD = try RecoveryFiles.openFolder(job, create: false); defer { close(directoryFD) }
        try FileSafety.requireUnused(RecoveryFiles.payload(job))
        let initialSnapshot = try RecoveryFiles.snapshot(job, directoryFD: directoryFD)
        guard RecoveryFiles.matchesContent(initialSnapshot, job) else {
            job.recovery = LocalRecovery(stage: .needsReview, retainedBytes: initialSnapshot.identity.size)
            job.lastError = "Managed recovery data changed. Permanent removal is blocked."
            try await persist(job); throw NestError.sourceChanged
        }
        let freeBefore = try RecoveryFiles.freeBytes(job)
        job.recovery?.stage = .removing; try await persist(job)
        let snapshot = try RecoveryFiles.snapshot(job, directoryFD: directoryFD)
        guard RecoveryFiles.matchesContent(snapshot, job) else {
            job.recovery = LocalRecovery(stage: .needsReview, retainedBytes: snapshot.identity.size)
            job.lastError = "Managed recovery data changed. Permanent removal is blocked."
            try await persist(job); throw NestError.sourceChanged
        }
        do { try RecoveryFiles.requireArchivedMetadata(job, directoryFD: directoryFD) }
        catch {
            job.recovery?.stage = .needsReview
            job.lastError = "Managed recovery data has unsupported metadata or its metadata could not be checked. It has been retained; use Put back."
            try await persist(job); throw error
        }
        var current = stat()
        guard fstatat(directoryFD, RecoveryFiles.name(job), &current, AT_SYMLINK_NOFOLLOW) == 0,
              FileSafety.identity(current) == snapshot.identity else { throw NestError.sourceChanged }
        guard unlinkat(directoryFD, RecoveryFiles.name(job), 0) == 0 else { throw NestError.unsafePath("managed removal failed") }
        _ = fsync(directoryFD)
        let freeAfter = (try? RecoveryFiles.freeBytes(job)) ?? freeBefore
        // This is an observed filesystem delta, not a promise of APFS block ownership.
        job.recovery = LocalRecovery(stage: .removed, observedFreeSpaceIncrease: max(0, freeAfter - freeBefore), completedAt: Date())
        job.lastError = nil; try await persist(job)
    }

    public func putBackOriginal(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id)
        defer { withExtendedLifetime(lease) {} }
        var job = try await catalog.job(id)
        guard job.recovery?.stage == .retained || job.recovery?.stage == .needsReview else { throw NestError.invalidManifest }
        let parent = job.source.deletingLastPathComponent()
        try safety.validate(parent, root: job.approvedRoot)
        let parentFD = try FileSafety.openDirectory(parent); defer { close(parentFD) }
        let recoveryFD = try RecoveryFiles.openFolder(job, create: false); defer { close(recoveryFD) }
        // Put-back preserves changed data too; no existing original is replaced.
        guard renameatx_np(recoveryFD, RecoveryFiles.name(job), parentFD, job.source.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw NestError.conflict }
        let restored = try safety.snapshot(job.source, root: job.approvedRoot)
        if restored.sha256 == job.snapshot.sha256, restored.identity.size == job.snapshot.identity.size { job.snapshot = restored }
        job.recovery = nil; job.lastError = nil; try await persist(job)
    }

    /// Read/reconcile only. Never completes an interrupted permanent removal.
    public func reconcileRecovery() async throws {
        guard !running else { return }
        running = true; defer { running = false }
        var cursor: Int64 = 0
        while true {
            let page = try await catalog.interruptedRecoveries(afterRowID: cursor)
            guard let next = page.cursor else { break }
            cursor = next
            for record in page.jobs {
                let lease: OperationLease
                do { lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: record.id) }
                catch NestError.busy { continue }
                defer { withExtendedLifetime(lease) {} }
                // The previous owner may have finished after this page was read.
                var job = try await catalog.job(record.id)
                guard job.recovery?.stage == .moving || job.recovery?.stage == .removing else { continue }
                let payloadExists = FileManager.default.fileExists(atPath: RecoveryFiles.payload(job).path)
                let sourceExists = FileManager.default.fileExists(atPath: job.source.path)
                if job.recovery?.stage == .removing && !payloadExists {
                    job.recovery = LocalRecovery(stage: .removed, completedAt: Date())
                    job.lastError = "Local removal completed before restart. Its free-space change was not measured."
                } else if payloadExists {
                    let folderFD = try RecoveryFiles.openFolder(job, create: false); defer { close(folderFD) }
                    let snapshot = try RecoveryFiles.snapshot(job, directoryFD: folderFD)
                    job.recovery = LocalRecovery(stage: RecoveryFiles.matchesContent(snapshot, job) && !sourceExists ? .retained : .needsReview, retainedBytes: snapshot.identity.size)
                } else if sourceExists { job.recovery = nil }
                else {
                    job.recovery = LocalRecovery(stage: .needsReview)
                    job.lastError = "Original and managed recovery copy are unavailable. The cloud archive has not been changed."
                }
                try await persist(job)
            }
        }
    }
}
