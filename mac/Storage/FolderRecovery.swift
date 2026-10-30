import Foundation
import Darwin
import CryptoKit

public struct FolderLocalRecovery: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case moving, puttingBack, retained, needsReview, removing, removed }
    public var stage: Stage
    public var retainedBytes: Int64
    public var observedFreeSpaceIncrease: Int64
    public var completedAt: Date?
    public var removedFiles: [String]
    public var removedDirectories: [String]
    public var pendingRemoval: String?
    public init(stage: Stage, retainedBytes: Int64 = 0, observedFreeSpaceIncrease: Int64 = 0, completedAt: Date? = nil,
                removedFiles: [String] = [], removedDirectories: [String] = [], pendingRemoval: String? = nil) {
        self.stage = stage; self.retainedBytes = retainedBytes; self.observedFreeSpaceIncrease = observedFreeSpaceIncrease
        self.completedAt = completedAt; self.removedFiles = removedFiles; self.removedDirectories = removedDirectories; self.pendingRemoval = pendingRemoval
    }
}

public struct FolderArchiveHealthReport: Codable, Sendable {
    public let jobID: UUID
    public let status: ArchiveHealthStatus
    public let checkedAt: Date
    public let detail: String
}

public struct RecoveredFolderArchive: Codable, Sendable, Identifiable {
    public var id: UUID { manifest.id }
    public let manifest: FolderArchiveManifest
    public let manifestID: String
    public let verifiedAt: Date
    public init(manifest: FolderArchiveManifest, manifestID: String, verifiedAt: Date = Date()) {
        self.manifest = manifest; self.manifestID = manifestID; self.verifiedAt = verifiedAt
    }
}

public struct RecoveredFolderSummary: Sendable, Identifiable {
    public let id: UUID
    public let folderName: String
    public let createdAt: Date
    public let verifiedAt: Date
    public let fileCount: Int
    public let totalBytes: Int64
    public let manifestID: String
}

enum FolderRecoveryFiles {
    static let folder = ".cloudnest-folder-recovery"
    static func name(_ id: UUID) -> String { id.uuidString + ".payload" }
    static func location(_ job: FolderArchiveJob) -> URL { job.source.deletingLastPathComponent().appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name(job.id), isDirectory: true) }
    static func openContainer(_ source: URL, create: Bool) throws -> Int32 {
        let parent = try FileSafety.openDirectory(source.deletingLastPathComponent()); defer { close(parent) }
        if create, mkdirat(parent, folder, 0o700) != 0, errno != EEXIST { throw NestError.unsafePath("cannot create folder recovery container") }
        let fd = openat(parent, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.unsafePath("folder recovery container unavailable") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw NestError.unsafePath("folder recovery container must be private and owned by you") }
        return fd
    }
    static func openRoot(_ job: FolderArchiveJob) throws -> Int32 {
        let parent = try openContainer(job.source, create: false); defer { close(parent) }
        let fd = openat(parent, name(job.id), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.unsafePath("managed folder is unavailable") }
        return fd
    }
    static func openRelative(_ path: String, root: Int32, directory: Bool) throws -> Int32 {
        let parts = path.isEmpty ? [] : try FolderArchiveManifest.components(path)
        var fd = dup(root)
        guard fd >= 0 else { throw NestError.unsafePath("managed folder unavailable") }
        for (index, part) in parts.enumerated() {
            let mustBeDirectory = index < parts.count - 1 || directory
            let next = openat(fd, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (mustBeDirectory ? O_DIRECTORY : 0))
            close(fd)
            guard next >= 0 else { throw NestError.unsafePath("managed folder member unavailable or linked") }; fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { close(fd); throw NestError.unsafePath("managed member changed type") }
        return fd
    }
    static func requirePortableMetadata(_ fd: Int32, expected: FolderEntryMetadata) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, UInt16(info.st_mode & 0o777) == expected.mode else { throw NestError.sourceChanged }
        guard expected.ownerID == getuid(), expected.groupID == getgid(), info.st_uid == getuid(), info.st_gid == getgid(),
              info.st_mode & 0o7000 == 0, info.st_flags == 0,
              expected.isDirectory || info.st_nlink == 1,
              !expected.isDirectory || expected.mode & 0o300 == 0o300 else {
            throw NestError.unsafePath("special permissions, ownership, flags or hard-link topology are not restorable; retain this folder locally")
        }
        try FileSafety.requireArchivedMetadata(descriptor: fd, provenance: expected.provenance)
        // ACLs are not represented in this portable format. Never silently
        // erase a permission grant/denial by deleting the only local original.
        // Query successful descriptor metadata separately from the ACL's
        // presence. acl_get_fd_np alone conflates "no ACL property" (ENOENT)
        // with retrieval failures on some macOS versions.
        guard let security = filesec_init() else { throw NestError.unsafePath("cannot allocate security metadata query") }
        defer { filesec_free(security) }
        var secured = stat(), hasACL: Int32 = 0
        guard fstatx_np(fd, &secured, security) == 0, FileSafety.identity(secured) == FileSafety.identity(info),
              filesec_query_property(security, FILESEC_ACL, &hasACL) == 0 else { throw NestError.unsafePath("cannot verify access-control metadata") }
        guard hasACL == 0 else { throw NestError.unsafePath("folder members with access-control lists must remain local") }

    }
    static func restoreMetadata(_ fd: Int32, metadata: FolderEntryMetadata) throws {
        // Stage remains behind a mode-0700 root until every member is verified.
        // A portable manifest is untrusted data, not permission to share files
        // with local groups or other users. Preserve owner read/write/execute;
        // retain original sharing bits as evidence in the manifest only.
        let mode = metadata.mode & 0o700
        guard fchown(fd, getuid(), getgid()) == 0, fchmod(fd, mode_t(mode)) == 0 else { throw NestError.unsafePath("cannot restore POSIX permissions") }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(metadata.modifiedSeconds), tv_nsec: Int(metadata.modifiedNanos))]
        guard futimens(fd, &times) == 0 else { throw NestError.unsafePath("cannot restore modification time") }
    }
    static func freeBytes(_ source: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: source.deletingLastPathComponent().path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber else { throw NestError.invalidResponse }; return bytes.int64Value
    }
}

/// Complete remote content health independent of a local source catalog.
public struct FolderArchiveHealthChecker: Sendable {
    private let remote: any ArchiveRemote
    public init(remote: any ArchiveRemote) { self.remote = remote }
    public func verify(_ archive: RecoveredFolderArchive) async throws {
        let data = try archive.manifest.encoded()
        let digest = CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let root = try await remote.metadata(id: archive.manifestID)
        guard root.trashed == false, Int64(root.size ?? "") == Int64(data.count), root.sha256Checksum == digest else { throw NestError.verificationFailed }
        for file in archive.manifest.files {
            try Task.checkCancellation()
            let metadata = try await remote.metadata(id: file.manifest.driveFileID)
            guard metadata.trashed == false, Int64(metadata.size ?? "") == file.manifest.size,
                  metadata.sha256Checksum == file.manifest.sha256 else { throw NestError.verificationFailed }
        }
    }
    public func check(_ archive: RecoveredFolderArchive) async -> FolderArchiveHealthReport {
        do {
            try await verify(archive)
            return FolderArchiveHealthReport(jobID: archive.id, status: .healthy, checkedAt: Date(), detail: "Drive root manifest and every embedded file reference match their size and SHA-256 evidence.")
        } catch NestError.http(404) {
            return FolderArchiveHealthReport(jobID: archive.id, status: .missing, checkedAt: Date(), detail: "A folder manifest or archived file is missing. Keep local recovery data.")
        } catch NestError.verificationFailed {
            return FolderArchiveHealthReport(jobID: archive.id, status: .mismatch, checkedAt: Date(), detail: "Folder content or manifest no longer matches. Cleanup is blocked.")
        } catch {
            return FolderArchiveHealthReport(jobID: archive.id, status: .unavailable, checkedAt: Date(), detail: "Folder health could not be established. No local data was changed.")
        }
    }
}
