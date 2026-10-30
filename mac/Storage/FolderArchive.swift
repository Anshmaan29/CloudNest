import Foundation
import CryptoKit
import Darwin

/// Portable content manifest. Child original paths are informational only;
/// inode information stays in the private session. Restore asks for a destination.
public struct FolderArchiveManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let folderName: String
    public let createdAt: Date
    public let directories: [String]
    public let files: [FolderArchiveFile]
    public static let maximumEntries = 10_000
    public static let maximumBytes = 16 * 1024 * 1024

    public init(id: UUID, folderName: String, createdAt: Date, directories: [String], files: [FolderArchiveFile]) {
        schemaVersion = 2; self.id = id; self.folderName = folderName; self.createdAt = createdAt
        self.directories = directories; self.files = files
    }
    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") && $0.utf8.count <= 255
        }) else { throw NestError.invalidManifest }
        return parts
    }
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    public func validate() throws {
        guard schemaVersion == 2, try Self.components(folderName).count == 1,
              directories.count + files.count <= Self.maximumEntries else { throw NestError.invalidManifest }
        var directoryKeys = Set<String>(), allKeys = Set<String>()
        var totalBytes: Int64 = 0
        for path in directories {
            _ = try Self.components(path)
            let key = Self.key(path)
            guard allKeys.insert(key).inserted else { throw NestError.invalidManifest }
            directoryKeys.insert(key)
        }
        for file in files {
            let parts = try Self.components(file.relativePath)
            try file.manifest.validate()
            let sum = totalBytes.addingReportingOverflow(file.manifest.size)
            guard !sum.overflow else { throw NestError.invalidManifest }; totalBytes = sum.partialValue
            guard parts.last == file.manifest.fileName, allKeys.insert(Self.key(file.relativePath)).inserted else { throw NestError.invalidManifest }
        }
        // Every parent must be explicitly represented as a directory. A file can
        // never be interpreted as an ancestor, even on a case-insensitive volume.
        for path in directories + files.map(\.relativePath) {
            let parts = try Self.components(path)
            for count in 1..<parts.count {
                guard directoryKeys.contains(Self.key(parts.prefix(count).joined(separator: "/"))) else { throw NestError.invalidManifest }
            }
        }
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw NestError.invalidManifest }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw NestError.invalidManifest }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Self.self, from: data)
        try manifest.validate(); return manifest
    }
    public static func read(from url: URL) throws -> Self {
        let parent = try FileSafety.openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.invalidManifest }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NestError.invalidManifest }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try decode(data)
    }
}

public struct FolderArchiveFile: Codable, Sendable {
    public let relativePath: String
    public let manifest: ArchiveManifest
    public init(relativePath: String, manifest: ArchiveManifest) { self.relativePath = relativePath; self.manifest = manifest }
}

private struct FolderDirectory: Codable, Sendable, Equatable {
    let relativePath: String
    let identity: FileIdentity
}
private struct FolderChild: Codable, Sendable {
    let relativePath: String
    let jobID: UUID
}
public struct FolderArchiveJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let approvedRoot: URL
    public let createdAt: Date
    public var state: TransferState = .queued
    public var completedFiles = 0
    public let totalFiles: Int
    public let totalBytes: Int64
    public var lastError: String?
    public var manifest: FolderArchiveManifest?
    public var remoteManifestID: String?
    fileprivate var offset: Int64 = 0
    fileprivate var directories: [FolderDirectory]
    fileprivate var children: [FolderChild]
    /// Lightweight UI/list representation. Full content is loaded only by ID.
    public var summary: FolderArchiveJob {
        var copy = self; copy.directories = []; copy.children = []; copy.manifest = nil; return copy
    }
    fileprivate init(id: UUID, source: URL, approvedRoot: URL, directories: [FolderDirectory], children: [FolderChild], totalBytes: Int64) {
        self.id = id; self.source = source; self.approvedRoot = approvedRoot; createdAt = Date()
        self.directories = directories; self.children = children; totalFiles = children.count; self.totalBytes = totalBytes
    }
}

/// Folder operations reuse the verified single-file engine. No operation here
/// removes or moves a source; folder-wide reclaim requires a separate safety design.
public actor FolderArchiveCoordinator {
    private let catalog: Catalog
    private let remote: any ArchiveRemote
    private let secrets: any SecretStore
    private let safety: FileSafety
    private let fileCoordinator: ArchiveCoordinator
    private let onFolderChanged: @Sendable (FolderArchiveJob) async -> Void
    private let sessionDirectory: URL
    private var running = false
    public init(catalog: Catalog, remote: any ArchiveRemote, secrets: any SecretStore = KeychainStore(), safety: FileSafety = FileSafety(), onFolderChanged: @escaping @Sendable (FolderArchiveJob) async -> Void = { _ in }, onFileChanged: @escaping @Sendable (ArchiveJob) async -> Void = { _ in }) {
        self.catalog = catalog; self.remote = remote; self.secrets = secrets; self.safety = safety
        self.onFolderChanged = onFolderChanged
        fileCoordinator = ArchiveCoordinator(catalog: catalog, remote: remote, secrets: secrets, safety: safety, onJobChanged: onFileChanged)
        sessionDirectory = catalog.directory.appendingPathComponent("folder-archives", isDirectory: true)
    }
    private func directory() throws -> Int32 {
        let catalogFD = try FileSafety.openDirectory(catalog.directory); defer { close(catalogFD) }
        if mkdirat(catalogFD, "folder-archives", 0o700) != 0 && errno != EEXIST { throw NestError.database("cannot create folder catalog") }
        let fd = openat(catalogFD, "folder-archives", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.unsafePath("folder catalog is unavailable") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw NestError.unsafePath("folder catalog permissions") }
        return fd
    }
    private func write(_ data: Data, name: String) throws {
        let fd = try directory(); defer { close(fd) }
        let temporary = ".pending-" + UUID().uuidString
        let payload = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard payload >= 0 else { throw NestError.database("cannot save folder session") }
        let file = FileHandle(fileDescriptor: payload, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(fd, temporary, 0) }
        try file.write(contentsOf: data); try file.synchronize()
        guard renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw NestError.database("cannot commit folder session") }
    }
    private func persist(_ job: FolderArchiveJob) async throws {
        try write(JSONEncoder().encode(job), name: job.id.uuidString + ".session.json")
        await onFolderChanged(job.summary)
    }
    public func manifestURL(for id: UUID) -> URL { sessionDirectory.appendingPathComponent(id.uuidString + ".cloudnest-folder.json") }
    public func job(_ id: UUID) throws -> FolderArchiveJob {
        let fd = try directory(); defer { close(fd) }
        let payload = openat(fd, id.uuidString + ".session.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard payload >= 0 else { throw NestError.invalidManifest }
        let file = FileHandle(fileDescriptor: payload, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(payload, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 64 * 1024 * 1024 else { throw NestError.invalidManifest }
        let data = try file.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
        let job = try JSONDecoder().decode(FolderArchiveJob.self, from: data)
        guard job.id == id, job.children.count <= FolderArchiveManifest.maximumEntries else { throw NestError.invalidManifest }
        return job
    }
    public func jobs(limit: Int = 100, offset: Int = 0) throws -> [FolderArchiveJob] {
        let fd = try directory(); defer { close(fd) }
        let names = try Self.names(in: fd, maximum: 100_000).filter { $0.hasSuffix(".session.json") }
        let ranked = names.compactMap { name -> (UUID, Int64, Int64)? in
            guard let id = UUID(uuidString: String(name.dropLast(".session.json".count))) else { return nil }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return (id, Int64(info.st_birthtimespec.tv_sec), Int64(info.st_birthtimespec.tv_nsec))
        }.sorted { $0.1 == $1.1 ? $0.2 > $1.2 : $0.1 > $1.1 }
        let start = min(ranked.count, max(0, offset)), count = min(500, max(1, limit))
        return try ranked.dropFirst(start).prefix(count).map { item in
            try autoreleasepool { try job(item.0).summary }
        }
    }
    private static func names(in descriptor: Int32, maximum: Int) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw NestError.unsafePath("cannot enumerate folder") }
        guard let directory = fdopendir(copy) else { close(copy); throw NestError.unsafePath("cannot enumerate folder") }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw NestError.unsafePath("folder enumeration failed") }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximum else { throw NestError.unsafePath("folder exceeds the configured entry budget") }
            result.append(name)
        }
        return result.sorted()
    }
    private func tree(_ source: URL, approvedRoot: URL) throws -> (directories: [FolderDirectory], files: [String]) {
        try safety.validate(source, root: approvedRoot)
        let rootFD = try FileSafety.openDirectory(source); defer { close(rootFD) }
        var directories: [FolderDirectory] = [], files: [String] = [], keys = Set<String>()
        func walk(_ current: URL, relative: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 64 else { throw NestError.unsafePath("folder nesting exceeds 64 levels") }
            try safety.validate(current, root: approvedRoot)
            let fd = try FileSafety.openDirectory(current); defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0 else { throw NestError.unsafePath("folder unavailable") }
            directories.append(FolderDirectory(relativePath: relative, identity: FileSafety.identity(before)))
            let names = try Self.names(in: fd, maximum: FolderArchiveManifest.maximumEntries)
            for name in names {
                let url = current.appendingPathComponent(name)
                try Task.checkCancellation()
                guard directories.count + files.count <= FolderArchiveManifest.maximumEntries else { throw NestError.unsafePath("folder exceeds 10,000 entries; choose smaller subfolders") }
                try safety.validate(url, root: approvedRoot)
                let path = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
                _ = try FolderArchiveManifest.components(path)
                guard keys.insert(FolderArchiveManifest.key(path)).inserted else { throw NestError.unsafePath("case or Unicode filename conflict") }
                var info = stat()
                guard fstatat(fd, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NestError.unsafePath("folder member unavailable") }
                if info.st_mode & S_IFMT == S_IFDIR { try walk(url, relative: path, depth: depth + 1) }
                else if info.st_mode & S_IFMT == S_IFREG { files.append(path) }
                else { throw NestError.unsafePath("folder contains a link or non-regular file") }
            }
            guard fstat(fd, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after) else { throw NestError.sourceChanged }
        }
        try walk(source, relative: "", depth: 0)
        guard directories.count - 1 + files.count <= FolderArchiveManifest.maximumEntries else { throw NestError.unsafePath("folder exceeds 10,000 entries") }
        return (directories, files)
    }
    public func enqueue(source: URL, approvedRoot: URL) async throws -> FolderArchiveJob {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let initial = try tree(source, approvedRoot: approvedRoot)
        _ = try FolderArchiveManifest.components(source.lastPathComponent)
        let parentID = UUID()
        var children: [FolderChild] = [], totalBytes: Int64 = 0
        for relative in initial.files {
            try Task.checkCancellation()
            let child = try await fileCoordinator.enqueue(source: source.appendingPathComponent(relative), approvedRoot: approvedRoot, folderArchiveID: parentID)
            let sum = totalBytes.addingReportingOverflow(child.snapshot.identity.size)
            guard !sum.overflow else { throw NestError.invalidManifest }; totalBytes = sum.partialValue
            children.append(FolderChild(relativePath: relative, jobID: child.id))
        }
        let final = try tree(source, approvedRoot: approvedRoot)
        guard initial.directories == final.directories, initial.files == final.files else { throw NestError.sourceChanged }
        let job = FolderArchiveJob(id: parentID, source: source, approvedRoot: approvedRoot, directories: initial.directories, children: children, totalBytes: totalBytes)
        try await persist(job); return job
    }
    private func checkSource(_ job: FolderArchiveJob, hashFiles: Bool) async throws {
        let current = try tree(job.source, approvedRoot: job.approvedRoot)
        guard current.directories == job.directories, current.files == job.children.map(\.relativePath) else { throw NestError.sourceChanged }
        for child in job.children {
            try Task.checkCancellation()
            let file = try await catalog.job(child.jobID)
            let expected = job.source.appendingPathComponent(child.relativePath)
            guard file.source == expected, file.approvedRoot == job.approvedRoot, file.folderArchiveID == job.id else { throw NestError.invalidManifest }
            if hashFiles {
                guard try safety.snapshot(expected, root: job.approvedRoot) == file.snapshot else { throw NestError.sourceChanged }
            } else {
                let handle = try safety.openSource(expected, root: job.approvedRoot); defer { try? handle.close() }
                var info = stat()
                guard fstat(handle.fileDescriptor, &info) == 0, FileSafety.identity(info) == file.snapshot.identity else { throw NestError.sourceChanged }
            }
        }
    }
    public func run(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id)
        defer { withExtendedLifetime(lease) {} }
        var job = try self.job(id)
        if job.state == .verified { return }
        do {
            try await checkSource(job, hashFiles: false)
            job.state = .uploading; job.lastError = nil; try await persist(job)
            var manifests: [FolderArchiveFile] = []
            for child in job.children {
                try Task.checkCancellation()
                try await fileCoordinator.run(child.jobID)
                let file = try await catalog.job(child.jobID)
                guard file.state == .verified, let remoteID = file.remoteID, let fileManifestID = file.manifestID else { throw NestError.verificationFailed }
                // A resumed folder may contain children verified in a previous
                // process. Recheck both remote objects rather than trusting state.
                guard try await remote.metadata(id: remoteID).matches(file.snapshot) else { throw NestError.verificationFailed }
                let fileManifestData = try ArchiveManifest(job: file, driveFileID: remoteID).encoded()
                let fileManifestChecksum = SHA256.hash(data: fileManifestData).map { String(format: "%02x", $0) }.joined()
                let fileManifestInfo = try await remote.metadata(id: fileManifestID)
                guard fileManifestInfo.trashed == false, Int64(fileManifestInfo.size ?? "") == Int64(fileManifestData.count),
                      fileManifestInfo.sha256Checksum == fileManifestChecksum else { throw NestError.verificationFailed }
                manifests.append(FolderArchiveFile(relativePath: child.relativePath, manifest: ArchiveManifest(job: file, driveFileID: remoteID)))
                job.completedFiles = manifests.count
                // Every child is already durable in SQLite. Bound large plan
                // rewrites without losing resume correctness; state is rebuilt
                // from verified children on retry. UI progress stays per-file.
                if manifests.count % 32 == 0 || manifests.count == job.totalFiles { try await persist(job) }
                else { await onFolderChanged(job.summary) }
            }
            try await checkSource(job, hashFiles: true)
            let manifest = FolderArchiveManifest(id: job.id, folderName: job.source.lastPathComponent, createdAt: job.createdAt,
                                                directories: job.directories.map(\.relativePath).filter { !$0.isEmpty }, files: manifests)
            let data = try manifest.encoded()
            try write(data, name: id.uuidString + ".cloudnest-folder.json")
            job.manifest = manifest
            try await uploadManifest(data, job: &job)
            try await checkSource(job, hashFiles: true)
            job.state = .verified; job.lastError = nil; try await persist(job)
            try await secrets.remove("folder-upload-" + id.uuidString)
        } catch {
            job.lastError = (error as? NestError)?.localizedDescription ?? (error is CancellationError ? "Paused. Resume to continue this folder." : "Folder transfer interrupted. Originals are retained; resume to retry.")
            try await persist(job); throw error
        }
    }
    private func uploadManifest(_ data: Data, job: inout FolderArchiveJob) async throws {
        if job.remoteManifestID == nil { job.remoteManifestID = try await remote.allocateID(); try await persist(job) }
        guard let id = job.remoteManifestID else { throw NestError.invalidManifest }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func matches(_ info: RemoteFile) -> Bool { info.trashed == false && info.sha256Checksum == checksum && Int64(info.size ?? "") == Int64(data.count) }
        do {
            let info = try await remote.metadata(id: id)
            guard matches(info) else { throw NestError.verificationFailed }
            job.offset = Int64(data.count); job.state = .uploaded; try await persist(job); return
        } catch NestError.http(404) { /* Upload not committed yet. */ }
        let secretKey = "folder-upload-" + job.id.uuidString
        var session: URL?
        if let stored = try await secrets.read(secretKey), let url = URL(string: String(decoding: stored, as: UTF8.self)) {
            do {
                let result = try await remote.status(session: url, total: Int64(data.count))
                guard result.offset >= 0, result.offset <= Int64(data.count) else { throw NestError.invalidResponse }
                session = url; job.offset = result.offset
                if result.complete { job.state = .uploaded }
            } catch NestError.http(404) { try await secrets.remove(secretKey) }
        }
        if session == nil {
            let url = try await remote.begin(id: id, name: job.id.uuidString + ".cloudnest-folder.json", size: Int64(data.count), jobID: job.id)
            try await secrets.write(secretKey, value: Data(url.absoluteString.utf8)); session = url; job.offset = 0
        }
        guard let session else { throw NestError.invalidResponse }
        while job.offset < Int64(data.count) {
            try Task.checkCancellation()
            let end = min(data.count, Int(job.offset) + ArchiveCoordinator.chunkBytes)
            let chunk = data.subdata(in: Int(job.offset)..<end)
            let progress = try await remote.send(session: session, data: chunk, offset: job.offset, total: Int64(data.count))
            guard progress.offset > job.offset, progress.offset <= Int64(data.count) else { throw NestError.invalidResponse }
            job.offset = progress.offset; try await persist(job)
            if progress.complete { break }
        }
        guard matches(try await remote.metadata(id: id)) else { throw NestError.verificationFailed }
        job.state = .uploaded; try await persist(job)
    }
    private func openRelativeDirectory(_ components: [String], from descriptor: Int32) throws -> Int32 {
        var current = dup(descriptor)
        guard current >= 0 else { throw NestError.unsafePath("restore folder unavailable") }
        for part in components {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw NestError.unsafePath("restore folder replaced") }; current = next
        }
        return current
    }
    private func removeKnownStaging(files: [String: FileIdentity], directories: [String], stageFD: Int32, parentFD: Int32, stageName: String) {
        // Remove only entries named in our verified manifest. Unexpected injected
        // entries are retained rather than recursively erased.
        for (path, identity) in files {
            let parts = path.split(separator: "/").map(String.init)
            if let parent = try? openRelativeDirectory(Array(parts.dropLast()), from: stageFD) {
                var info = stat()
                if fstatat(parent, parts.last!, &info, AT_SYMLINK_NOFOLLOW) == 0, FileSafety.identity(info) == identity {
                    _ = unlinkat(parent, parts.last!, 0)
                }
                close(parent)
            }
        }
        for path in directories.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let parts = path.split(separator: "/").map(String.init)
            if let parent = try? openRelativeDirectory(Array(parts.dropLast()), from: stageFD) {
                _ = unlinkat(parent, parts.last!, AT_REMOVEDIR); close(parent)
            }
        }
        var original = stat(), current = stat()
        if fstat(stageFD, &original) == 0, fstatat(parentFD, stageName, &current, AT_SYMLINK_NOFOLLOW) == 0,
           original.st_dev == current.st_dev, original.st_ino == current.st_ino {
            _ = unlinkat(parentFD, stageName, AT_REMOVEDIR)
        }
    }
    public func restore(manifest: FolderArchiveManifest, destination: URL) async throws -> URL {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        try manifest.validate(); try safety.validate(destination, root: destination)
        let target = destination.appendingPathComponent(manifest.folderName, isDirectory: true)
        try safety.validateDestination(target, root: destination)
        let parentFD = try FileSafety.openDirectory(destination); defer { close(parentFD) }
        var existing = stat()
        guard fstatat(parentFD, manifest.folderName, &existing, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else { throw NestError.conflict }
        let stageName = ".cloudnest-folder-restore-" + UUID().uuidString
        guard mkdirat(parentFD, stageName, 0o700) == 0 else { throw NestError.unsafePath("cannot create folder restore staging") }
        let stageFD = openat(parentFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw NestError.unsafePath("folder restore staging unavailable") }
        defer { close(stageFD) }
        var installed = false
        var restoredFiles: [String: FileIdentity] = [:], createdDirectories: [String] = []
        defer { if !installed { removeKnownStaging(files: restoredFiles, directories: createdDirectories, stageFD: stageFD, parentFD: parentFD, stageName: stageName) } }
        let stage = destination.appendingPathComponent(stageName, isDirectory: true)
        for path in manifest.directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            try Task.checkCancellation()
            let parts = try FolderArchiveManifest.components(path)
            let directoryFD = try openRelativeDirectory(Array(parts.dropLast()), from: stageFD); defer { close(directoryFD) }
            guard mkdirat(directoryFD, parts.last!, 0o700) == 0 else { throw NestError.conflict }
            createdDirectories.append(path)
            try safety.validate(stage.appendingPathComponent(path), root: stage)
        }
        for file in manifest.files {
            try Task.checkCancellation()
            let parts = try FolderArchiveManifest.components(file.relativePath)
            let parent = parts.dropLast().reduce(stage) { $0.appendingPathComponent($1, isDirectory: true) }
            _ = try await fileCoordinator.restore(manifest: file.manifest, destination: parent)
            let directoryFD = try openRelativeDirectory(Array(parts.dropLast()), from: stageFD); defer { close(directoryFD) }
            var info = stat()
            guard fstatat(directoryFD, parts.last!, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NestError.sourceChanged }
            restoredFiles[file.relativePath] = FileSafety.identity(info)
        }
        try Task.checkCancellation()
        let staged = try tree(stage, approvedRoot: stage)
        guard Set(staged.directories.map(\.relativePath).filter { !$0.isEmpty }) == Set(manifest.directories),
              Set(staged.files) == Set(manifest.files.map(\.relativePath)) else { throw NestError.verificationFailed }
        for file in manifest.files {
            try Task.checkCancellation()
            let content = try safety.snapshot(stage.appendingPathComponent(file.relativePath), root: stage)
            guard content.sha256 == file.manifest.sha256, content.identity.size == file.manifest.size,
                  content.identity == restoredFiles[file.relativePath] else { throw NestError.verificationFailed }
        }
        try safety.validate(destination, root: destination)
        try safety.validateDestination(target, root: destination)
        let currentFD = try FileSafety.openDirectory(destination); defer { close(currentFD) }
        var before = stat(), after = stat(), stageInfo = stat(), namedStage = stat()
        guard fstat(parentFD, &before) == 0, fstat(currentFD, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              fstat(stageFD, &stageInfo) == 0, fstatat(parentFD, stageName, &namedStage, AT_SYMLINK_NOFOLLOW) == 0,
              stageInfo.st_dev == namedStage.st_dev, stageInfo.st_ino == namedStage.st_ino else { throw NestError.unsafePath("restore destination moved") }
        guard fsync(stageFD) == 0 else { throw NestError.unsafePath("cannot synchronize restored folder") }
        guard renameatx_np(parentFD, stageName, parentFD, manifest.folderName, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw NestError.conflict }; throw NestError.unsafePath("cannot install restored folder")
        }
        installed = true; _ = fsync(parentFD)
        return target
    }
}
