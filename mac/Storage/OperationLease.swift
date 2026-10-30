import Foundation
import Darwin

/// A cooperative, process-death-safe lease shared by the app and CLI.
/// Keep the object alive for the complete operation. Lock files are never
/// unlinked: replacing a lock inode would allow two independent holders.
public final class OperationLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }

    public static func acquire(catalogDirectory: URL, jobID: UUID) throws -> OperationLease {
        let directory = try FileSafety.openDirectory(catalogDirectory); defer { close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == getuid(), parent.st_mode & 0o077 == 0 else {
            throw NestError.unsafePath("operation catalog must be private and owned by you")
        }
        let name = ".operation-" + jobID.uuidString + ".lock"
        let descriptor = openat(directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw NestError.unsafePath("operation lease unavailable") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            close(descriptor); throw NestError.unsafePath("operation lease must be a private regular file")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw NestError.busy }
            throw NestError.unsafePath("operation lease could not be established")
        }
        var named = stat()
        guard fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == named.st_dev, info.st_ino == named.st_ino else {
            _ = flock(descriptor, LOCK_UN); close(descriptor)
            throw NestError.unsafePath("operation lease was replaced")
        }
        return OperationLease(descriptor)
    }
}
