import Foundation
import CryptoKit
import Darwin

public struct DockerBackupLimits: Sendable {
    public var maximumBytes: Int64 = 20_000_000_000
    public var metadataTimeout: TimeInterval = 15
    public var transferTimeout: TimeInterval = 3600
    public init() {}
}
public struct ResolvedDockerImage: Sendable { public let reference: String; public let id: String }
public struct DockerImageBackupManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let selectedReference: String
    public let imageID: String
    public let archiveName: String
    public let bytes: Int64
    public let sha256: String
}
public struct DockerBackupReview: Sendable {
    public let directory: URL
    public let manifest: DockerImageBackupManifest
    public let manifestSHA256: String
}
public struct DockerBackupResult: Sendable {
    public let directory: URL
    public let manifest: DockerImageBackupManifest
    public var manifestURL: URL { directory.appendingPathComponent("CLOUDNEST_DOCKER.json") }
}

/// Only image save/load against an existing local Unix-socket daemon. No pulls,
/// builds, containers, volumes, disk images, shell commands or daemon startup.
public struct DockerImageBackup: Sendable {
    public let executable: URL
    public let socket: URL
    public let protectedRoots: [URL]
    public let limits: DockerBackupLimits
    public init(executable: URL, socket: URL, protectedRoots: [URL] = [], limits: DockerBackupLimits = DockerBackupLimits()) {
        self.executable = executable; self.socket = socket; self.protectedRoots = protectedRoots; self.limits = limits
    }
    /// Call only after an explicit user action; this does not launch Docker.
    public static func local(protectedRoots: [URL] = [], limits: DockerBackupLimits = DockerBackupLimits()) throws -> Self {
        let candidates = ["/Applications/Docker.app/Contents/Resources/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        guard let binary = candidates.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw NestError.unsafePath("Docker CLI was not found. Install Docker separately; CloudNest never starts or installs it.")
        }
        let candidatesSockets = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/run/docker.sock"), URL(fileURLWithPath: "/var/run/docker.sock")]
        guard let socket = candidatesSockets.map({ $0.resolvingSymlinksInPath() }).first(where: { url in var value = stat(); return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFSOCK }) else {
            throw NestError.unsafePath("No running local Docker socket was found. Start Docker yourself, then check again.")
        }
        return Self(executable: binary, socket: socket, protectedRoots: protectedRoots, limits: limits)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func validReference(_ value: String) -> Bool {
        value.utf8.count <= 256 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._/:-]*(?:@sha256:[a-f0-9]{64})?$", options: .regularExpression) != nil
    }
    private static func validID(_ value: String) -> Bool { value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil }
    private func validate() throws {
        guard limits.maximumBytes > 0, limits.maximumBytes <= 100_000_000_000,
              limits.metadataTimeout.isFinite, limits.metadataTimeout > 0, limits.metadataTimeout <= 60,
              limits.transferTimeout.isFinite, limits.transferTimeout > 0, limits.transferTimeout <= 86400 else { throw NestError.unsafePath("invalid Docker operation budget") }
        var binary = stat(), endpoint = stat()
        guard executable.isFileURL, socket.isFileURL, lstat(executable.path, &binary) == 0,
              binary.st_mode & S_IFMT == S_IFREG, binary.st_mode & 0o022 == 0, binary.st_mode & 0o111 != 0,
              binary.st_uid == getuid() || binary.st_uid == 0,
              lstat(socket.path, &endpoint) == 0, endpoint.st_mode & S_IFMT == S_IFSOCK,
              endpoint.st_uid == getuid() || endpoint.st_uid == 0 else { throw NestError.unsafePath("Docker executable or local socket is unavailable or unsafe; no daemon was started") }
    }
    private func run(_ arguments: [String], input: FileHandle? = nil, session: DockerPrivateSession, timeout: TimeInterval, maximumOutput: Int64,
                     consume: (Data) throws -> Void) throws {
        try validate(); try Task.checkCancellation()
        let process = Process(), pipe = Pipe(), ended = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["--config", session.directory.path, "--host", "unix://" + socket.path] + arguments
        process.currentDirectoryURL = session.directory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "TMPDIR": session.directory.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = input ?? FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { throw NestError.unsafePath("Docker CLI could not be launched") }
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        defer { try? pipe.fileHandleForReading.close() }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_048_576, alignment: 16); defer { buffer.deallocate() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var count: Int64 = 0, eof = false
        do {
            while !eof || process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("Docker exceeded its time budget. An interrupted import may already have added image layers.") }
                if !eof {
                    var event = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                    let ready = poll(&event, 1, 50)
                    if ready < 0 && errno != EINTR { throw NestError.invalidResponse }
                    if ready > 0 {
                        let readCount = read(fd, buffer, 1_048_576)
                        if readCount > 0 {
                            guard count <= maximumOutput - Int64(readCount) else { throw NestError.unsafePath("Docker output exceeded the configured byte budget") }
                            count += Int64(readCount)
                            try autoreleasepool { try consume(Data(bytes: buffer, count: readCount)) }
                        } else if readCount == 0 { eof = true }
                        else if errno != EAGAIN && errno != EINTR { throw NestError.invalidResponse }
                    }
                } else { _ = ended.wait(timeout: .now() + .milliseconds(50)) }
            }
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw NestError.unsafePath("Docker operation failed. Check your local daemon and selected image. No partial backup was published.") }
        } catch {
            if process.isRunning {
                process.terminate()
                if ended.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                    _ = ended.wait(timeout: .now() + 2)
                }
            }
            throw error
        }
    }
    private func text(_ arguments: [String], session: DockerPrivateSession) throws -> String {
        var data = Data()
        try run(arguments, session: session, timeout: limits.metadataTimeout, maximumOutput: 65_536) { data.append($0) }
        guard let value = String(data: data, encoding: .utf8) else { throw NestError.invalidResponse }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func checkConnection() throws -> String {
        let session = try DockerPrivateSession(); defer { session.clean() }
        let version = try text(["version", "--format", "{{.Server.Version}}"], session: session)
        guard !version.isEmpty, version.utf8.count <= 80, !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw NestError.invalidResponse }
        return version
    }
    public func resolve(reference: String) throws -> ResolvedDockerImage {
        guard Self.validReference(reference) else { throw NestError.unsafePath("enter one local Docker image name, tag or SHA-256 ID") }
        let session = try DockerPrivateSession(); defer { session.clean() }
        let id = try text(["image", "inspect", "--format", "{{.ID}}", reference], session: session)
        guard Self.validID(id) else { throw NestError.unsafePath("Docker did not resolve a single immutable SHA-256 image ID") }
        return ResolvedDockerImage(reference: reference, id: id)
    }
    public func export(image: ResolvedDockerImage, to destination: URL, onProgress: @Sendable (Int64) -> Void = { _ in }) throws -> DockerBackupResult {
        guard Self.validID(image.id), Self.validReference(image.reference) else { throw NestError.invalidResponse }
        try FileSafety(protectedRoots: protectedRoots).validate(destination, root: destination)
        let parent = try FileSafety.openDirectory(destination); defer { close(parent) }
        let parentIdentity = try DockerPrivateSession.identity(parent)
        let recoveryName = ".cloudnest-recovery"
        if mkdirat(parent, recoveryName, 0o700) != 0 && errno != EEXIST { throw NestError.unsafePath("cannot create private Docker staging") }
        let recovery = openat(parent, recoveryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard recovery >= 0 else { throw NestError.unsafePath("unsafe Docker staging parent") }; defer { close(recovery) }
        try DockerPrivateSession.requirePrivateDirectory(recovery)
        let id = UUID(), stageName = "docker-" + id.uuidString, finalName = "DockerImage-" + id.uuidString
        guard mkdirat(recovery, stageName, 0o700) == 0 else { throw NestError.unsafePath("cannot reserve Docker backup") }
        let stage = openat(recovery, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw NestError.unsafePath("Docker staging unavailable") }; defer { close(stage) }
        let archive = openat(stage, "image.tar", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard archive >= 0 else { throw NestError.unsafePath("cannot reserve image archive") }; defer { close(archive) }
        let session = try DockerPrivateSession(); defer { session.clean() }
        guard try text(["image", "inspect", "--format", "{{.ID}}", image.id], session: session) == image.id else { throw NestError.sourceChanged }
        var hash = SHA256(), bytes: Int64 = 0, nextProgress: TimeInterval = 0
        try run(["image", "save", image.id], session: session, timeout: limits.transferTimeout, maximumOutput: limits.maximumBytes) { data in
            var volume = statfs()
            guard fstatfs(stage, &volume) == 0, Int64(volume.f_bavail) * Int64(volume.f_bsize) > 512_000_000 + Int64(data.count) else { throw NestError.unsafePath("destination needs a 512 MB safety margin") }
            try DockerPrivateSession.write(data, to: archive); hash.update(data: data); bytes += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextProgress { onProgress(bytes); nextProgress = now + 0.2 }
        }
        guard bytes > 0, fsync(archive) == 0 else { throw NestError.unsafePath("empty or unwritten Docker archive") }
        let expectedHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let snapshot = try DockerPrivateSession.hash(archive, maximumBytes: limits.maximumBytes)
        guard snapshot.0 == bytes, snapshot.1 == expectedHash else { throw NestError.sourceChanged }
        let archiveIdentity = try DockerPrivateSession.identity(archive)
        let manifest = DockerImageBackupManifest(schemaVersion: 1, id: id, createdAt: Date(), selectedReference: image.reference, imageID: image.id, archiveName: "image.tar", bytes: bytes, sha256: expectedHash)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        let metadata = openat(stage, "CLOUDNEST_DOCKER.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard metadata >= 0 else { throw NestError.unsafePath("cannot reserve Docker manifest") }
        let metadataIdentity: FileIdentity
        do { try DockerPrivateSession.write(manifestData, to: metadata); guard fsync(metadata) == 0 else { throw NestError.invalidResponse }; metadataIdentity = try DockerPrivateSession.identity(metadata); close(metadata) } catch { close(metadata); throw error }
        let stageURL = destination.appendingPathComponent(recoveryName).appendingPathComponent(stageName)
        guard try Set(FileManager.default.contentsOfDirectory(atPath: stageURL.path)) == ["image.tar", "CLOUDNEST_DOCKER.json"],
              try DockerPrivateSession.identity(parent).device == parentIdentity.device,
              try DockerPrivateSession.identity(parent).inode == parentIdentity.inode else { throw NestError.sourceChanged }
        let namedParent = try FileSafety.openDirectory(destination); defer { close(namedParent) }
        let namedStage = try FileSafety.openDirectory(stageURL); defer { close(namedStage) }
        let namedRecovery = try FileSafety.openDirectory(destination.appendingPathComponent(recoveryName)); defer { close(namedRecovery) }
        let parentNow = try DockerPrivateSession.identity(namedParent), stageNow = try DockerPrivateSession.identity(namedStage), stageOpen = try DockerPrivateSession.identity(stage)
        guard parentNow.device == parentIdentity.device, parentNow.inode == parentIdentity.inode,
              stageNow.device == stageOpen.device, stageNow.inode == stageOpen.inode,
              try DockerPrivateSession.identity(namedRecovery).inode == DockerPrivateSession.identity(recovery).inode else { throw NestError.sourceChanged }
        var namedArchive = stat(), namedMetadata = stat()
        guard fstatat(stage, "image.tar", &namedArchive, AT_SYMLINK_NOFOLLOW) == 0, FileSafety.identity(namedArchive) == archiveIdentity,
              fstatat(stage, "CLOUDNEST_DOCKER.json", &namedMetadata, AT_SYMLINK_NOFOLLOW) == 0, FileSafety.identity(namedMetadata) == metadataIdentity else { throw NestError.sourceChanged }
        try FileSafety(protectedRoots: protectedRoots).validateDestination(destination.appendingPathComponent(finalName), root: destination)
        guard fsync(stage) == 0, renameatx_np(recovery, stageName, parent, finalName, UInt32(RENAME_EXCL)) == 0 else { throw NestError.unsafePath("backup could not be exclusively published; private partial staging was retained") }
        _ = fsync(parent); onProgress(bytes)
        return DockerBackupResult(directory: destination.appendingPathComponent(finalName), manifest: manifest)
    }
    public static func review(directory: URL, maximumBytes: Int64 = 100_000_000_000) throws -> DockerBackupReview {
        let folder = try FileSafety.openDirectory(directory); defer { close(folder) }
        let fd = try DockerPrivateSession.openRegular("CLOUDNEST_DOCKER.json", in: folder); defer { close(fd) }
        let identity = try DockerPrivateSession.identity(fd)
        guard identity.size > 0, identity.size <= 16_384 else { throw NestError.invalidResponse }
        var data = Data(count: Int(identity.size))
        let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == data.count, try DockerPrivateSession.identity(fd) == identity else { throw NestError.sourceChanged }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DockerImageBackupManifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.archiveName == "image.tar", validID(manifest.imageID),
              manifest.bytes > 0, manifest.bytes <= maximumBytes, manifest.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              validReference(manifest.selectedReference) else { throw NestError.unsafePath("invalid Docker backup manifest") }
        return DockerBackupReview(directory: directory, manifest: manifest, manifestSHA256: digest(data))
    }
    /// Caller must obtain explicit user approval of this review immediately before invoking.
    /// Cancellation cannot undo layers already accepted by Docker's daemon.
    public func importBackup(approved review: DockerBackupReview) throws {
        try validate()
        let current = try Self.review(directory: review.directory, maximumBytes: limits.maximumBytes)
        guard current.manifestSHA256 == review.manifestSHA256 else { throw NestError.sourceChanged }
        let folder = try FileSafety.openDirectory(review.directory); defer { close(folder) }
        let source = try DockerPrivateSession.openRegular("image.tar", in: folder); defer { close(source) }
        let original = try DockerPrivateSession.identity(source)
        guard original.size == review.manifest.bytes else { throw NestError.sourceChanged }
        let session = try DockerPrivateSession(); defer { session.clean() }
        let staging = openat(session.fd, "verified-image.tar", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard staging >= 0 else { throw NestError.unsafePath("cannot reserve verified import staging") }
        defer { close(staging) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_048_576, alignment: 16); defer { buffer.deallocate() }
        var hash = SHA256(), bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = read(source, buffer, 1_048_576)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NestError.invalidResponse }; if count == 0 { break }
            guard bytes <= limits.maximumBytes - Int64(count) else { throw NestError.unsafePath("import exceeds the configured byte budget") }
            var space = statfs()
            guard fstatfs(staging, &space) == 0, Int64(space.f_bavail) * Int64(space.f_bsize) > 512_000_000 + Int64(count) else { throw NestError.unsafePath("verified import staging needs a 512 MB safety margin") }
            try autoreleasepool { let data = Data(bytes: buffer, count: count); try DockerPrivateSession.write(data, to: staging); hash.update(data: data) }
            bytes += Int64(count)
        }
        let sourceUnchanged = try DockerPrivateSession.identity(source) == original
        if sourceUnchanged, bytes == original.size { session.remember("verified-image.tar", descriptor: staging) }
        guard bytes == review.manifest.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == review.manifest.sha256,
              sourceUnchanged, fsync(staging) == 0 else { throw NestError.sourceChanged }
        let verified = try DockerPrivateSession.hash(staging, maximumBytes: limits.maximumBytes)
        guard verified.0 == bytes, verified.1 == review.manifest.sha256, lseek(staging, 0, SEEK_SET) == 0 else { throw NestError.sourceChanged }
        session.remember("verified-image.tar", descriptor: staging)
        let inputDescriptor = dup(staging); guard inputDescriptor >= 0 else { throw NestError.invalidResponse }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true); defer { try? input.close() }
        try run(["image", "load", "--quiet"], input: input, session: session, timeout: limits.transferTimeout, maximumOutput: 65_536) { _ in }
        guard try text(["image", "inspect", "--format", "{{.ID}}", review.manifest.imageID], session: session) == review.manifest.imageID else { throw NestError.unsafePath("Docker completed load but the expected image ID could not be confirmed") }
    }
}

private final class DockerPrivateSession {
    let directory: URL
    let fd: Int32
    private var known: [String: FileIdentity] = [:]
    init() throws {
        // Foundation can normalize /private/var back to the /var symlink.
        // Canonicalize this OS-owned temporary location with POSIX realpath;
        // user-selected backup paths still use the strict no-follow walker.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NestError.unsafePath("temporary folder unavailable") }
        let root = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
        let parent = try Self.openTemporaryDirectory(root); defer { close(parent) }
        let name = "cloudnest-docker-" + UUID().uuidString
        guard mkdirat(parent, name, 0o700) == 0 else { throw NestError.unsafePath("cannot create private Docker session") }
        let opened = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw NestError.unsafePath("private Docker session unavailable") }
        let config = openat(opened, "config.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard config >= 0 else { close(opened); throw NestError.unsafePath("cannot reserve private Docker configuration") }
        let configIdentity: FileIdentity
        do { try Self.write(Data("{\"auths\":{}}\n".utf8), to: config); configIdentity = try Self.identity(config); close(config) }
        catch { close(config); close(opened); throw error }
        directory = root.appendingPathComponent(name); fd = opened; known["config.json"] = configIdentity
    }
    deinit { close(fd) }
    func remember(_ name: String, descriptor: Int32) { known[name] = try? Self.identity(descriptor) }
    func clean() {
        for (name, expected) in known {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileSafety.identity(info) == expected { _ = unlinkat(fd, name, 0) }
        }
        if let parent = try? Self.openTemporaryDirectory(directory.deletingLastPathComponent()) {
            defer { close(parent) }; var named = stat(), opened = stat()
            if fstat(fd, &opened) == 0, fstatat(parent, directory.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
               opened.st_ino == named.st_ino, opened.st_dev == named.st_dev { _ = unlinkat(parent, directory.lastPathComponent, AT_REMOVEDIR) }
        }
    }
    // Only for the POSIX-canonical OS temporary path created above. Unlike
    // standardizedFileURL, this does not turn /private/var back into /var.
    private static func openTemporaryDirectory(_ url: URL) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.invalidResponse }
        for component in url.path.split(separator: "/") {
            guard component != ".", component != ".." else { close(fd); throw NestError.invalidResponse }
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); close(fd)
            guard next >= 0 else { throw NestError.unsafePath("temporary folder unavailable or changed") }; fd = next
        }
        return fd
    }
    static func requirePrivateDirectory(_ fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o077 == 0 else { throw NestError.unsafePath("Docker staging must be owner-only") }
    }
    static func identity(_ fd: Int32) throws -> FileIdentity { var info = stat(); guard fstat(fd, &info) == 0 else { throw NestError.invalidResponse }; return FileSafety.identity(info) }
    static func openRegular(_ name: String, in parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NestError.unsafePath("backup file unavailable") }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_flags & UInt32(SF_DATALESS) == 0 else { close(fd); throw NestError.unsafePath("backup must be a fully local regular file without links") }
        return fd
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NestError.unsafePath("backup disk write failed") }; offset += count
            }
        }
    }
    static func hash(_ fd: Int32, maximumBytes: Int64) throws -> (Int64, String) {
        let before = try identity(fd); guard before.size <= maximumBytes, lseek(fd, 0, SEEK_SET) == 0 else { throw NestError.unsafePath("backup exceeds byte budget") }
        var hash = SHA256(), total: Int64 = 0
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1_048_576, alignment: 16); defer { pointer.deallocate() }
        while true {
            try Task.checkCancellation(); let count = read(fd, pointer, 1_048_576)
            if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw NestError.invalidResponse }; if count == 0 { break }
            guard total <= maximumBytes - Int64(count) else { throw NestError.unsafePath("backup changed size") }
            autoreleasepool { hash.update(data: Data(bytes: pointer, count: count)) }; total += Int64(count)
        }
        guard try identity(fd) == before, total == before.size else { throw NestError.sourceChanged }
        return (total, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
