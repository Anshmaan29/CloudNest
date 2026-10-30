import Foundation
import Darwin

// All operations address exactly one catalogued job. There is no Trash API,
// recursive deletion, background removal, or directory-emptying operation.
enum RecoveryFiles {
    static let folder = ".cloudnest-recovery"
    static func name(_ job: ArchiveJob) -> String { job.id.uuidString + ".payload" }
    static func directory(_ job: ArchiveJob) -> URL { job.approvedRoot.appendingPathComponent(folder) }
    static func payload(_ job: ArchiveJob) -> URL { directory(job).appendingPathComponent(name(job)) }
    static func openFolder(_ job: ArchiveJob, create: Bool) throws -> Int32 {
        let root = try FileSafety.openDirectory(job.approvedRoot); defer { close(root) }
        if create, mkdirat(root, folder, 0o700) != 0, errno != EEXIST { throw NestError.unsafePath("cannot create recovery folder") }
        let descriptor = openat(root, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NestError.unsafePath("recovery folder unavailable") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor); throw NestError.unsafePath("recovery folder must be private and owned by you")
        }
        return descriptor
    }
    static func snapshot(_ job: ArchiveJob, directoryFD: Int32) throws -> Snapshot {
        let fd = openat(directoryFD, name(job), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.unsafePath("managed recovery file unavailable") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        return try FileSafety.snapshot(file)
    }
    static func requireArchivedMetadata(_ job: ArchiveJob, directoryFD: Int32) throws {
        let fd = openat(directoryFD, name(job), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.unsafePath("managed recovery file unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NestError.unsafePath("managed recovery payload is not a regular file") }
        try FileSafety.requireArchivedMetadata(descriptor: fd, provenance: job.snapshot.provenance)
    }
    static func freeBytes(_ job: ArchiveJob) throws -> Int64 {
        let values = try FileManager.default.attributesOfFileSystem(forPath: job.approvedRoot.path)
        guard let bytes = values[.systemFreeSize] as? NSNumber else { throw NestError.invalidResponse }
        return bytes.int64Value
    }
    static func matchesContent(_ snapshot: Snapshot, _ job: ArchiveJob) -> Bool {
        snapshot.sha256 == job.snapshot.sha256 && snapshot.identity.size == job.snapshot.identity.size
        && snapshot.identity.inode == job.snapshot.identity.inode && snapshot.identity.device == job.snapshot.identity.device
    }
}
