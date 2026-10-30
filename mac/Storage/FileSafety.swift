import Foundation
import CryptoKit
import Darwin

public struct FileSafety: Sendable {
    public let protectedRoots: [URL]
    public init(protectedRoots: [URL] = []) { self.protectedRoots = protectedRoots }
    public static func contains(_ root: URL, _ child: URL) -> Bool {
        let r = root.standardizedFileURL.path, c = child.standardizedFileURL.path
        return c == r || c.hasPrefix(r + "/")
    }
    public func validate(_ url: URL, root: URL) throws {
        guard url.isFileURL, root.isFileURL, Self.contains(root, url) else { throw NestError.unsafePath("outside approved folder") }
        let foldedPath = url.standardizedFileURL.path.lowercased()
        let blocked = ["/system", "/library", "/applications", "/private", "/dev", "/bin", "/sbin", "/usr"]
        guard !blocked.contains(where: { foldedPath == $0 || foldedPath.hasPrefix($0 + "/") }),
              !protectedRoots.contains(where: { root in
                  let protectedPath = root.standardizedFileURL.path.lowercased()
                  return foldedPath == protectedPath || foldedPath.hasPrefix(protectedPath + "/")
              }) else { throw NestError.unsafePath("protected folder") }
        let components = url.standardizedFileURL.pathComponents
        let forbidden = Set(["library", "cloudstorage", ".trash", ".git", ".docker", ".cloudnest-recovery", "node_modules", ".venv", "__pycache__"])
        guard !components.map({ $0.lowercased() }).contains(where: { forbidden.contains($0) || $0.hasPrefix("googledrive") || $0.hasPrefix("google drive") || $0.hasPrefix("onedrive") || $0 == "dropbox" || $0.hasSuffix(".app") || $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".photolibrary") }),
              root.pathComponents.count > 2 else { throw NestError.unsafePath("system, cloud, package or generated content") }
        var current = URL(fileURLWithPath: "/")
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw NestError.unsafePath("symbolic link") }
                guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw NestError.unsafePath("cloud placeholder") }
            } else { throw NestError.unsafePath("unavailable path") }
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                throw NestError.unsafePath("repository; project hibernation requires a later safety workflow")
            }
            if ["PG_VERSION", "WiredTiger", "ibdata1", "data.mdb"].contains(where: { FileManager.default.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                throw NestError.unsafePath("database storage directory")
            }
        }
        let ext = url.pathExtension.lowercased()
        guard !["db", "sqlite", "sqlite3", "realm", "mdb", "lmdb", "rdb", "aof", "wal", "shm", "raw", "qcow", "qcow2", "vmdk", "vhd", "vhdx", "icloud"].contains(ext),
              !foldedPath.hasSuffix("-wal"), !foldedPath.hasSuffix("-shm") else { throw NestError.unsafePath("database, virtual disk or placeholder") }
    }
    /// Conservative cleanup guard, invoked only for an explicitly selected
    /// original/recovery copy. Never runs during scans or while idle.
    static func requireUnused(_ url: URL) throws {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", url.path]
        process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { throw NestError.unsafePath("cannot establish whether the file is in use") }
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { try Task.checkCancellation(); usleep(20_000) }
        guard !process.isRunning else { process.terminate(); throw NestError.unsafePath("file-use check timed out; close active applications and retry") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        guard [0, 1].contains(process.terminationStatus), diagnostics.isEmpty else { throw NestError.unsafePath("file-use status is uncertain") }
        let pids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        guard !pids.contains(where: { $0 != getpid() }) else { throw NestError.unsafePath("file is open in another process") }
    }
    public static func identity(_ info: stat) -> FileIdentity {
        FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                     modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                     changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
    // Walk with openat/O_NOFOLLOW so a directory swapped for a symlink between
    // policy validation and opening cannot redirect the operation elsewhere.
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw NestError.unsafePath("not a file URL") }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw NestError.unsafePath("cannot open directory") }
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { throw NestError.unsafePath("directory unavailable or replaced by a link") }
            descriptor = next
        }
        return descriptor
    }
    func openSource(_ url: URL, root: URL) throws -> FileHandle {
        try validate(url, root: root)
        let parent = try Self.openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NestError.unsafePath("cannot open source") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { close(descriptor); throw NestError.unsafePath("not a local regular file") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    public func snapshot(_ url: URL, root: URL) throws -> Snapshot {
        let file = try openSource(url, root: root)
        defer { try? file.close() }
        return try Self.snapshot(file)
    }
    static func snapshot(_ file: FileHandle) throws -> Snapshot {
        let fd = file.fileDescriptor
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw NestError.unsafePath("not a regular file") }
        var hash = SHA256()
        // Foundation's NSData backing can remain autoreleased until a whole
        // task finishes. Drain each block rather than retaining a file's worth.
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
            hash.update(data: chunk); return true
        }) {}
        guard fstat(fd, &after) == 0, Self.identity(before) == Self.identity(after) else { throw NestError.sourceChanged }
        return Snapshot(identity: Self.identity(after), sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

public struct FileScanner: Sendable {
    public let safety: FileSafety
    public init(safety: FileSafety = FileSafety()) { self.safety = safety }
    public func scan(root: URL, minimumBytes: Int64 = 10_000_000, minimumAgeDays: Int = 0, limit: Int = 10_000, now: Date = Date()) throws -> ScanReport {
        try safety.validate(root, root: root)
        var report = ScanReport(), seen = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw NestError.unsafePath("cannot enumerate folder") }
        var visited = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            if visited > 100_000 || report.candidates.count >= limit { report.truncated = true; break }
            do { try safety.validate(url, root: root) } catch { report.excluded += 1; enumerator.skipDescendants(); continue }
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let key = "\(info.st_dev):\(info.st_ino)"
            guard seen.insert(key).inserted, info.st_size >= minimumBytes,
                  Double(info.st_mtimespec.tv_sec) <= now.timeIntervalSince1970 - Double(max(0, minimumAgeDays)) * 86_400 else { continue }
            let ext = url.pathExtension.lowercased()
            let category = ["mp4", "mov", "mkv", "wav"].contains(ext) ? "Media" : ["zip", "gz", "tar", "7z", "dmg"].contains(ext) ? "Archives" : "Files"
            report.candidates.append(Candidate(url: url, logicalBytes: info.st_size, allocatedBytes: Int64(info.st_blocks) * 512,
                                               modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)), category: category))
        }
        report.candidates.sort { $0.allocatedBytes > $1.allocatedBytes }
        return report
    }
}
