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
    public let metadata: [FolderEntryMetadata]?
    public static let maximumEntries = 10_000
    public static let maximumBytes = 16 * 1024 * 1024

    public init(id: UUID, folderName: String, createdAt: Date, directories: [String], files: [FolderArchiveFile], metadata: [FolderEntryMetadata]? = nil) {
        schemaVersion = 2; self.id = id; self.folderName = folderName; self.createdAt = createdAt
        self.directories = directories; self.files = files; self.metadata = metadata
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
        if let metadata {
            guard metadata.count == allKeys.count + 1 else { throw NestError.invalidManifest }
            var seen = Set<String>()
            let fileManifests = Dictionary(uniqueKeysWithValues: files.map { (Self.key($0.relativePath), $0.manifest) })
            for entry in metadata {
                if !entry.relativePath.isEmpty { _ = try Self.components(entry.relativePath) }
                let key = Self.key(entry.relativePath)
                guard seen.insert(key).inserted, entry.mode <= 0o777,
                      entry.modifiedNanos >= 0, entry.modifiedNanos < 1_000_000_000,
                      entry.provenance.map({ $0.count <= 4096 }) ?? true,
                      entry.relativePath.isEmpty ? entry.isDirectory : allKeys.contains(key),
                      entry.isDirectory == (entry.relativePath.isEmpty || directoryKeys.contains(key)) else { throw NestError.invalidManifest }
                if let file = fileManifests[key] {
                    guard entry.provenance == file.provenance else { throw NestError.invalidManifest }
                }
            }
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

public struct FolderEntryMetadata: Codable, Sendable, Equatable {
    public let relativePath: String
    public let isDirectory: Bool
    public let mode: UInt16
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let provenance: Data?
    public let ownerID: UInt32?
    public let groupID: UInt32?
    public init(relativePath: String, isDirectory: Bool, mode: UInt16, modifiedSeconds: Int64, modifiedNanos: Int64, provenance: Data?, ownerID: UInt32? = nil, groupID: UInt32? = nil) {
        self.relativePath = relativePath; self.isDirectory = isDirectory; self.mode = mode
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanos = modifiedNanos; self.provenance = provenance
        self.ownerID = ownerID; self.groupID = groupID
    }
    static func capture(_ fd: Int32, relativePath: String, directory: Bool) throws -> Self {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw NestError.unsafePath("metadata unavailable") }
        return Self(relativePath: relativePath, isDirectory: directory, mode: UInt16(info.st_mode & 0o777),
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                    provenance: try FileSafety.provenance(descriptor: fd), ownerID: info.st_uid, groupID: info.st_gid)
    }
}
private struct FolderDirectory: Codable, Sendable, Equatable {
    let relativePath: String
    let identity: FileIdentity
    let metadata: FolderEntryMetadata?
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
    public var recovery: FolderLocalRecovery?
    fileprivate var offset: Int64 = 0
    fileprivate var directories: [FolderDirectory]
    fileprivate var children: [FolderChild]
    public var recoveryLocation: URL { FolderRecoveryFiles.location(self) }
    /// Lightweight UI/list representation. Full content is loaded only by ID.
    public var summary: FolderArchiveJob {
        var copy = self; copy.directories = []; copy.children = []; copy.manifest = nil; copy.recovery = recovery?.summary; return copy
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
        try await catalog.saveFolderRecoveryTotals(job)
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
        rewinddir(directory)
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
            directories.append(FolderDirectory(relativePath: relative, identity: FileSafety.identity(before), metadata: try FolderEntryMetadata.capture(fd, relativePath: relative, directory: true)))
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
    private func upgradeLegacyDirectoryEvidence(_ job: inout FolderArchiveJob) async throws {
        guard job.directories.contains(where: { $0.metadata == nil }) else { return }
        let current = try tree(job.source, approvedRoot: job.approvedRoot)
        guard current.files == job.children.map(\.relativePath), current.directories.count == job.directories.count else { throw NestError.sourceChanged }
        let originals = Dictionary(uniqueKeysWithValues: job.directories.map { ($0.relativePath, $0.identity) })
        for directory in current.directories { guard originals[directory.relativePath] == directory.identity else { throw NestError.sourceChanged } }
        for child in job.children {
            try Task.checkCancellation()
            let file = try await catalog.job(child.jobID)
            guard file.source == job.source.appendingPathComponent(child.relativePath), file.folderArchiveID == job.id,
                  try safety.snapshot(file.source, root: job.approvedRoot) == file.snapshot else { throw NestError.sourceChanged }
        }
        job.directories = current.directories
        try await persist(job)
    }
    public func run(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id)
        defer { withExtendedLifetime(lease) {} }
        var job = try self.job(id)
        if job.state == .verified { return }
        do {
            // Existing 0.3 queue entries have no private directory metadata. Add
            // it only after all original identities and content hashes match.
            try await upgradeLegacyDirectoryEvidence(&job)
            let preserveLegacyRoot = job.remoteManifestID != nil && job.manifest?.metadata == nil
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
            var metadata = try job.directories.map { directory -> FolderEntryMetadata in
                guard let metadata = directory.metadata else { throw NestError.invalidManifest }; return metadata
            }
            for child in job.children {
                let handle = try safety.openSource(job.source.appendingPathComponent(child.relativePath), root: job.approvedRoot)
                defer { try? handle.close() }
                metadata.append(try FolderEntryMetadata.capture(handle.fileDescriptor, relativePath: child.relativePath, directory: false))
            }
            let manifest = FolderArchiveManifest(id: job.id, folderName: job.source.lastPathComponent, createdAt: job.createdAt,
                                                directories: job.directories.map(\.relativePath).filter { !$0.isEmpty }, files: manifests, metadata: preserveLegacyRoot ? nil : metadata)
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
        if let metadata = manifest.metadata {
            for entry in metadata.filter({ !$0.relativePath.isEmpty }).sorted(by: { $0.relativePath.split(separator: "/").count > $1.relativePath.split(separator: "/").count }) {
                let fd = try FolderRecoveryFiles.openRelative(entry.relativePath, root: stageFD, directory: entry.isDirectory); defer { close(fd) }
                try FolderRecoveryFiles.restoreMetadata(fd, metadata: entry)
                if !entry.isDirectory {
                    var info = stat()
                    guard fstat(fd, &info) == 0 else { throw NestError.sourceChanged }
                    restoredFiles[entry.relativePath] = FileSafety.identity(info)
                }
            }
            if let rootMetadata = metadata.first(where: { $0.relativePath.isEmpty }) { try FolderRecoveryFiles.restoreMetadata(stageFD, metadata: rootMetadata) }
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
    private func verifiedManifest(_ job: FolderArchiveJob) async throws -> FolderArchiveManifest {
        guard job.state == .verified, let manifest = job.manifest, let rootID = job.remoteManifestID else { throw NestError.verificationFailed }
        try manifest.validate()
        guard manifest.id == job.id, manifest.files.count == job.children.count else { throw NestError.invalidManifest }
        let data = try manifest.encoded()
        let info = try await remote.metadata(id: rootID)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard info.trashed == false, info.sha256Checksum == digest, Int64(info.size ?? "") == Int64(data.count) else { throw NestError.verificationFailed }
        let byPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0.manifest) })
        for child in job.children {
            try Task.checkCancellation()
            let file = try await catalog.job(child.jobID)
            guard file.state == .verified, file.folderArchiveID == job.id,
                  let remoteID = file.remoteID, let manifestID = file.manifestID,
                  let embedded = byPath[child.relativePath],
                  try embedded.encoded() == ArchiveManifest(job: file, driveFileID: remoteID).encoded(),
                  try await remote.metadata(id: remoteID).matches(file.snapshot) else { throw NestError.verificationFailed }
            let fileData = try embedded.encoded()
            let fileDigest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
            let metadata = try await remote.metadata(id: manifestID)
            guard metadata.trashed == false, metadata.sha256Checksum == fileDigest,
                  Int64(metadata.size ?? "") == Int64(fileData.count) else { throw NestError.verificationFailed }
        }
        return manifest
    }
    public func health(_ id: UUID) async -> FolderArchiveHealthReport {
        do {
            let job = try self.job(id)
            guard job.state == .verified else {
                return FolderArchiveHealthReport(jobID: id, status: .unverified, checkedAt: Date(), detail: "This folder has not completed verification. All originals must remain local.")
            }
            _ = try await verifiedManifest(job)
            return FolderArchiveHealthReport(jobID: id, status: .healthy, checkedAt: Date(), detail: "Root manifest, every child file and every child recovery manifest match Drive size and SHA-256 metadata.")
        } catch NestError.http(404) {
            return FolderArchiveHealthReport(jobID: id, status: .missing, checkedAt: Date(), detail: "A folder archive object is missing from Drive. Keep all local recovery data.")
        } catch NestError.verificationFailed {
            return FolderArchiveHealthReport(jobID: id, status: .mismatch, checkedAt: Date(), detail: "Folder archive verification is incomplete or no longer matches. Local cleanup is blocked.")
        } catch {
            return FolderArchiveHealthReport(jobID: id, status: .unavailable, checkedAt: Date(), detail: "The complete folder archive could not be checked. No local data was changed.")
        }
    }
    private func requirePolicies(_ job: FolderArchiveJob, manifest: FolderArchiveManifest) throws {
        try safety.validatePolicy(job.source, root: job.approvedRoot)
        for path in manifest.directories + manifest.files.map(\.relativePath) {
            try safety.validatePolicy(job.source.appendingPathComponent(path), root: job.approvedRoot)
        }
    }
    private func requireCleanupMetadata(_ manifest: FolderArchiveManifest) throws -> [String: FolderEntryMetadata] {
        guard let values = manifest.metadata else { throw NestError.unsafePath("this legacy folder archive lacks permission and directory metadata; create a new archive before cleanup") }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.relativePath, $0) })
    }
    private func requireInventory(_ job: FolderArchiveJob, manifest: FolderArchiveManifest, root: Int32, removedFiles: Set<String> = [], removedDirectories: Set<String> = [], checkFileUse: Bool) async throws {
        let metadata = try requireCleanupMetadata(manifest)
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0 else { throw NestError.sourceChanged }
        let expectedDirectories = Set([""] + manifest.directories).subtracting(removedDirectories)
        let expectedFiles = Set(manifest.files.map(\.relativePath)).subtracting(removedFiles)
        var actualDirectories = Set<String>(), actualFiles = Set<String>()
        let sourceDirectories = Dictionary(uniqueKeysWithValues: job.directories.map { ($0.relativePath, $0.identity) })
        func walk(_ fd: Int32, path: String) throws {
            try Task.checkCancellation()
            actualDirectories.insert(path)
            guard expectedDirectories.contains(path), let original = sourceDirectories[path], let expected = metadata[path] else { throw NestError.sourceChanged }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == rootInfo.st_dev,
                  Int64(info.st_dev) == original.device, UInt64(info.st_ino) == original.inode else { throw NestError.sourceChanged }
            try FolderRecoveryFiles.requirePortableMetadata(fd, expected: expected)
            for name in try Self.names(in: fd, maximum: FolderArchiveManifest.maximumEntries) {
                let relative = path.isEmpty ? name : path + "/" + name
                var entry = stat()
                guard fstatat(fd, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { throw NestError.sourceChanged }
                if entry.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw NestError.sourceChanged }; defer { close(child) }
                    try walk(child, path: relative)
                } else if entry.st_mode & S_IFMT == S_IFREG { actualFiles.insert(relative) }
                else { throw NestError.unsafePath("managed folder contains a link or non-regular file") }
            }
        }
        try walk(root, path: "")
        guard actualDirectories == expectedDirectories, actualFiles == expectedFiles else { throw NestError.sourceChanged }
        for child in job.children where !removedFiles.contains(child.relativePath) {
            try Task.checkCancellation()
            guard let expected = metadata[child.relativePath] else { throw NestError.invalidManifest }
            let archived = try await catalog.job(child.jobID)
            let fd = try FolderRecoveryFiles.openRelative(child.relativePath, root: root, directory: false)
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
            let snapshot = try FileSafety.snapshot(file)
            guard snapshot.identity.device == Int64(rootInfo.st_dev), RecoveryFiles.matchesContent(snapshot, archived), snapshot.provenance == archived.snapshot.provenance,
                  snapshot.identity.modifiedSeconds == archived.snapshot.identity.modifiedSeconds,
                  snapshot.identity.modifiedNanos == archived.snapshot.identity.modifiedNanos else { throw NestError.sourceChanged }
            try FolderRecoveryFiles.requirePortableMetadata(fd, expected: expected)
            if checkFileUse { try FileSafety.requireUnused(FolderRecoveryFiles.location(job).appendingPathComponent(child.relativePath)) }
        }
    }
    /// Stage the complete verified folder on its original volume. No bytes are deleted.
    public func moveToRecovery(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id); defer { withExtendedLifetime(lease) {} }
        var job = try self.job(id)
        guard job.recovery == nil else { throw NestError.conflict }
        let manifest = try await verifiedManifest(job)
        try requirePolicies(job, manifest: manifest)
        _ = try requireCleanupMetadata(manifest)
        try await checkSource(job, hashFiles: true)
        let source = try FileSafety.openDirectory(job.source); defer { close(source) }
        // All non-portable metadata is rejected before moving the selected original.
        try await requireInventory(job, manifest: manifest, root: source, checkFileUse: false)
        for child in job.children { try FileSafety.requireUnused(job.source.appendingPathComponent(child.relativePath)) }
        let parent = try FileSafety.openDirectory(job.source.deletingLastPathComponent()); defer { close(parent) }
        let recovery = try FolderRecoveryFiles.openContainer(job.source, create: true); defer { close(recovery) }
        var before = stat(), current = stat()
        guard fstat(source, &before) == 0, fstatat(parent, job.source.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == current.st_dev, before.st_ino == current.st_ino else { throw NestError.sourceChanged }
        job.recovery = FolderLocalRecovery(stage: .moving, retainedBytes: job.totalBytes); try await persist(job)
        guard renameatx_np(parent, job.source.lastPathComponent, recovery, FolderRecoveryFiles.name(job.id), UInt32(RENAME_EXCL)) == 0 else {
            job.recovery = nil; try await persist(job); throw NestError.conflict
        }
        do {
            guard fsync(parent) == 0, fsync(recovery) == 0 else { throw NestError.unsafePath("folder move could not be synchronized") }
            let retained = try FolderRecoveryFiles.openRoot(job); defer { close(retained) }
            try await requireInventory(job, manifest: manifest, root: retained, checkFileUse: false)
            job.recovery?.stage = .retained; job.lastError = nil; try await persist(job)
        } catch {
            job.recovery?.stage = .needsReview
            job.lastError = "Folder changed during its move. All current data is retained; removal is blocked. Put back or restore from the cloud."
            try await persist(job); throw error
        }
    }
    public func putBackOriginal(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id); defer { withExtendedLifetime(lease) {} }
        var job = try self.job(id)
        guard let recovery = job.recovery, recovery.stage != .removed,
              recovery.removedFiles.isEmpty, recovery.removedDirectories.isEmpty, recovery.pendingRemoval == nil else {
            throw NestError.unsafePath("this folder is incomplete after approved cleanup; restore the complete archive instead")
        }
        try safety.validatePolicy(job.source, root: job.approvedRoot)
        try safety.validateDestination(job.source, root: job.source.deletingLastPathComponent())
        let parent = try FileSafety.openDirectory(job.source.deletingLastPathComponent()); defer { close(parent) }
        let retained = try FolderRecoveryFiles.openContainer(job.source, create: false); defer { close(retained) }
        let prior = job.recovery
        job.recovery?.stage = .puttingBack; try await persist(job)
        guard renameatx_np(retained, FolderRecoveryFiles.name(job.id), parent, job.source.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            job.recovery = prior; try await persist(job); throw NestError.conflict
        }
        let synchronized = fsync(parent) == 0 && fsync(retained) == 0
        // A changed folder may be put back safely, but only an exact inventory
        // updates the known directory identities for a subsequent fresh cleanup.
        if let current = try? tree(job.source, approvedRoot: job.approvedRoot), current.files == job.children.map(\.relativePath) {
            job.directories = current.directories
        }
        job.recovery = nil; job.lastError = synchronized ? nil : "Folder was put back, but filesystem synchronization was uncertain. Keep the cloud archive and verify it after restart."
        try await persist(job)
    }
    /// A fresh explicit approval is required on every call, including interrupted removal.
    public func permanentlyRemoveRecovery(_ id: UUID) async throws {
        guard !running else { throw NestError.busy }; running = true; defer { running = false }
        let lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id); defer { withExtendedLifetime(lease) {} }
        var job = try self.job(id)
        if job.recovery?.stage == .removing, job.recovery?.pendingRemoval != nil, let manifest = job.manifest {
            try normalizePendingRemoval(&job, manifest: manifest)
            try await persist(job)
            if job.recovery?.stage == .removed { return }
        }
        guard let previous = job.recovery, previous.stage == .retained || previous.stage == .removing else { throw NestError.verificationFailed }
        let manifest = try await verifiedManifest(job)
        try requirePolicies(job, manifest: manifest)
        let metadata = try requireCleanupMetadata(manifest)
        let root = try FolderRecoveryFiles.openRoot(job); defer { close(root) }
        var removedFiles = Set(previous.removedFiles), removedDirectories = Set(previous.removedDirectories)
        do { try await requireInventory(job, manifest: manifest, root: root, removedFiles: removedFiles, removedDirectories: removedDirectories, checkFileUse: true) }
        catch {
            job.recovery?.stage = removedFiles.isEmpty && removedDirectories.isEmpty ? .needsReview : .removing
            job.lastError = "Managed folder changed or cannot be safely checked. Keep its data; use Put back if complete, or restore the full archive."
            try await persist(job); throw error
        }
        let freeBefore = try FolderRecoveryFiles.freeBytes(job.source)
        job.recovery?.stage = .removing; try await persist(job)
        do {
            for child in job.children where !removedFiles.contains(child.relativePath) {
                try Task.checkCancellation()
                let archived = try await catalog.job(child.jobID)
                let fd = try FolderRecoveryFiles.openRelative(child.relativePath, root: root, directory: false)
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
                let snapshot = try FileSafety.snapshot(file)
                guard RecoveryFiles.matchesContent(snapshot, archived), let expected = metadata[child.relativePath] else { throw NestError.sourceChanged }
                try FolderRecoveryFiles.requirePortableMetadata(fd, expected: expected)
                try FileSafety.requireUnused(FolderRecoveryFiles.location(job).appendingPathComponent(child.relativePath))
                let parts = try FolderArchiveManifest.components(child.relativePath)
                let parent = try FolderRecoveryFiles.openRelative(parts.dropLast().joined(separator: "/"), root: root, directory: true); defer { close(parent) }
                job.recovery?.pendingRemoval = child.relativePath; try await persist(job)
                try Task.checkCancellation()
                var current = stat()
                guard fstatat(parent, parts.last!, &current, AT_SYMLINK_NOFOLLOW) == 0, FileSafety.identity(current) == snapshot.identity else { throw NestError.sourceChanged }
                guard unlinkat(parent, parts.last!, 0) == 0 else { throw NestError.unsafePath("managed folder member removal failed") }
                guard fsync(parent) == 0 else { throw NestError.unsafePath("managed file removal could not be synchronized") }
                removedFiles.insert(child.relativePath); job.recovery?.removedFiles = removedFiles.sorted(); job.recovery?.pendingRemoval = nil
                job.recovery?.retainedBytes = manifest.files.filter { !removedFiles.contains($0.relativePath) }.reduce(0) { $0 + $1.manifest.size }
                try await persist(job)
            }
            for path in manifest.directories.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) where !removedDirectories.contains(path) {
                try Task.checkCancellation()
                let parts = try FolderArchiveManifest.components(path)
                let directory = try FolderRecoveryFiles.openRelative(path, root: root, directory: true); defer { close(directory) }
                guard let expected = metadata[path] else { throw NestError.invalidManifest }
                try FolderRecoveryFiles.requirePortableMetadata(directory, expected: expected)
                guard try Self.names(in: directory, maximum: FolderArchiveManifest.maximumEntries).isEmpty else { throw NestError.sourceChanged }
                let parent = try FolderRecoveryFiles.openRelative(parts.dropLast().joined(separator: "/"), root: root, directory: true); defer { close(parent) }
                var pinned = stat(), named = stat()
                guard fstat(directory, &pinned) == 0,
                      let original = job.directories.first(where: { $0.relativePath == path }),
                      Int64(pinned.st_dev) == original.identity.device, UInt64(pinned.st_ino) == original.identity.inode else { throw NestError.sourceChanged }
                job.recovery?.pendingRemoval = path; try await persist(job)
                try Task.checkCancellation()
                guard fstatat(parent, parts.last!, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      FileSafety.identity(named) == FileSafety.identity(pinned) else { throw NestError.sourceChanged }
                guard unlinkat(parent, parts.last!, AT_REMOVEDIR) == 0 else { throw NestError.unsafePath("managed folder directory removal failed") }
                guard fsync(parent) == 0 else { throw NestError.unsafePath("managed directory removal could not be synchronized") }
                removedDirectories.insert(path)
                job.recovery?.removedDirectories = removedDirectories.sorted(); job.recovery?.pendingRemoval = nil; try await persist(job)
            }
            guard try Self.names(in: root, maximum: FolderArchiveManifest.maximumEntries).isEmpty, let rootMetadata = metadata[""] else { throw NestError.sourceChanged }
            try FolderRecoveryFiles.requirePortableMetadata(root, expected: rootMetadata)
            let container = try FolderRecoveryFiles.openContainer(job.source, create: false); defer { close(container) }
            var rootInfo = stat(), named = stat()
            guard fstat(root, &rootInfo) == 0, fstatat(container, FolderRecoveryFiles.name(id), &named, AT_SYMLINK_NOFOLLOW) == 0,
                  rootInfo.st_dev == named.st_dev, rootInfo.st_ino == named.st_ino else { throw NestError.sourceChanged }
            job.recovery?.pendingRemoval = ""; try await persist(job)
            try Task.checkCancellation()
            guard fstatat(container, FolderRecoveryFiles.name(id), &named, AT_SYMLINK_NOFOLLOW) == 0,
                  FileSafety.identity(rootInfo) == FileSafety.identity(named) else { throw NestError.sourceChanged }
            guard unlinkat(container, FolderRecoveryFiles.name(id), AT_REMOVEDIR) == 0 else { throw NestError.unsafePath("managed root removal failed") }
            guard fsync(container) == 0 else { throw NestError.unsafePath("managed root removal could not be synchronized") }
            let freeAfter = (try? FolderRecoveryFiles.freeBytes(job.source)) ?? freeBefore
            job.recovery = FolderLocalRecovery(stage: .removed, observedFreeSpaceIncrease: previous.observedFreeSpaceIncrease + max(0, freeAfter - freeBefore), completedAt: Date(), removedFiles: removedFiles.sorted(), removedDirectories: removedDirectories.sorted())
            job.lastError = nil; try await persist(job)
        } catch {
            let freeAfter = (try? FolderRecoveryFiles.freeBytes(job.source)) ?? freeBefore
            job.recovery?.observedFreeSpaceIncrease = previous.observedFreeSpaceIncrease + max(0, freeAfter - freeBefore)
            job.lastError = job.recovery?.stage == .removed ? "Removal completed but its catalog update was interrupted. Reopen Recovery Center to reconcile." : "Folder cleanup stopped. Remaining managed data is retained. Restore the complete archive, or review and explicitly approve cleanup again."
            try await persist(job); throw error
        }
    }
    private func normalizePendingRemoval(_ job: inout FolderArchiveJob, manifest: FolderArchiveManifest) throws {
        guard let pending = job.recovery?.pendingRemoval else { return }
        if pending.isEmpty {
            let container = try FolderRecoveryFiles.openContainer(job.source, create: false); defer { close(container) }
            var info = stat()
            if fstatat(container, FolderRecoveryFiles.name(job.id), &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT {
                guard Set(job.recovery?.removedFiles ?? []) == Set(manifest.files.map(\.relativePath)),
                      Set(job.recovery?.removedDirectories ?? []) == Set(manifest.directories) else { throw NestError.invalidManifest }
                job.recovery?.stage = .removed; job.recovery?.retainedBytes = 0; job.recovery?.pendingRemoval = nil; job.recovery?.completedAt = Date()
                job.lastError = "Folder removal completed before restart. Its final free-space change was not measured."; return
            }
            job.recovery?.pendingRemoval = nil; return
        }
        let isDirectory = manifest.directories.contains(pending)
        guard isDirectory || manifest.files.contains(where: { $0.relativePath == pending }) else { throw NestError.invalidManifest }
        let root = try FolderRecoveryFiles.openRoot(job); defer { close(root) }
        let parts = try FolderArchiveManifest.components(pending)
        let parent = try FolderRecoveryFiles.openRelative(parts.dropLast().joined(separator: "/"), root: root, directory: true); defer { close(parent) }
        var info = stat()
        if fstatat(parent, parts.last!, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw NestError.unsafePath("pending folder removal cannot be reconciled") }
            if isDirectory { if job.recovery?.removedDirectories.contains(pending) == false { job.recovery?.removedDirectories.append(pending) } }
            else if job.recovery?.removedFiles.contains(pending) == false { job.recovery?.removedFiles.append(pending) }
        }
        job.recovery?.pendingRemoval = nil
    }
    /// Reconcile records only. Never performs or automatically resumes deletion.
    public func reconcileRecovery() async throws {
        guard !running else { return }; running = true; defer { running = false }
        let sessions = try directory(); defer { close(sessions) }
        let ids = try Self.names(in: sessions, maximum: 100_000).compactMap { name -> UUID? in
            guard name.hasSuffix(".session.json") else { return nil }
            return UUID(uuidString: String(name.dropLast(".session.json".count)))
        }
        for id in ids {
                let lease: OperationLease
                do { lease = try OperationLease.acquire(catalogDirectory: catalog.directory, jobID: id) }
                catch NestError.busy { continue }
                defer { withExtendedLifetime(lease) {} }
                var job = try autoreleasepool { try self.job(id) }
                try await catalog.saveFolderRecoveryTotals(job)
                guard let manifest = job.manifest, job.recovery?.stage == .moving || job.recovery?.stage == .removing || job.recovery?.stage == .puttingBack else { continue }
                let location = FolderRecoveryFiles.location(job)
                let exists = FileManager.default.fileExists(atPath: location.path)
                var originalInfo = stat()
                let expectedRoot = job.directories.first(where: { $0.relativePath.isEmpty })?.identity
                let originalPresent = lstat(job.source.path, &originalInfo) == 0 && originalInfo.st_mode & S_IFMT == S_IFDIR
                    && Int64(originalInfo.st_dev) == expectedRoot?.device && UInt64(originalInfo.st_ino) == expectedRoot?.inode
                if job.recovery?.stage == .puttingBack {
                    if !exists, originalPresent {
                        if let current = try? tree(job.source, approvedRoot: job.approvedRoot), current.files == job.children.map(\.relativePath) { job.directories = current.directories }
                        job.recovery = nil; job.lastError = "Folder put-back completed before restart. No local data was deleted."
                    } else {
                        job.recovery?.stage = .needsReview
                        job.lastError = "Folder put-back was interrupted or its destination conflicts. Managed data is retained; inspect it before retrying."
                    }
                } else if !exists {
                    if job.recovery?.stage == .moving, originalPresent { job.recovery = nil }
                    else if job.recovery?.stage == .removing, job.recovery?.pendingRemoval == "" {
                        try normalizePendingRemoval(&job, manifest: manifest)
                    } else { job.recovery?.stage = .needsReview; job.lastError = "Managed folder is unavailable. Use the verified cloud archive for recovery." }
                } else if job.recovery?.stage == .moving {
                    do {
                        let root = try FolderRecoveryFiles.openRoot(job); defer { close(root) }
                        try await requireInventory(job, manifest: manifest, root: root, checkFileUse: false)
                        let sourceExists = FileManager.default.fileExists(atPath: job.source.path)
                        job.recovery?.stage = sourceExists ? .needsReview : .retained
                    } catch { job.recovery?.stage = .needsReview; job.lastError = "Managed folder needs review; no deletion was resumed." }
                } else {
                    try normalizePendingRemoval(&job, manifest: manifest)
                    let removed = Set(job.recovery?.removedFiles ?? [])
                    job.recovery?.retainedBytes = manifest.files.filter { !removed.contains($0.relativePath) }.reduce(0) { $0 + $1.manifest.size }
                    job.lastError = "Folder cleanup was interrupted. No deletion was resumed; a fresh explicit approval is required."
                }
                try await persist(job)
        }
    }

}
