import Foundation
import Darwin
import CryptoKit

public struct PostgresBackupLimits: Sendable {
    public var maximumBytes: Int64 = 20_000_000_000
    public var minimumFreeBytes: Int64 = 512_000_000
    public var metadataTimeout: TimeInterval = 15
    public var transferTimeout: TimeInterval = 600
    public init() {}
}
public struct ResolvedPostgresContainer: Sendable { public let reference: String; public let id: String }
public struct PostgresBackupManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let containerReference: String
    public let containerID: String
    public let database: String
    public let role: String
    public let archiveName: String
    public let bytes: Int64
    public let sha256: String
    public let permitsOriginalCleanup: Bool
}
public struct PostgresBackupReview: Sendable { public let directory: URL; public let manifest: PostgresBackupManifest; public let manifestSHA256: String }
public struct PostgresBackupResult: Sendable {
    public let directory: URL
    public let manifest: PostgresBackupManifest
    public var manifestURL: URL { directory.appendingPathComponent(PostgresBackup.manifestName) }
}
public struct PostgresRestorePlan: Sendable {
    public let id: UUID
    public let container: ResolvedPostgresContainer
    public let role: String
    public let review: PostgresBackupReview
    public var databaseName: String { "cloudnest_restore_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}
public struct PostgresRestoreResult: Sendable { public let databaseName: String; public let containerID: String; public let recoveryDirectory: URL }
public struct PostgresRestoreFailure: Error, LocalizedError, Sendable {
    public let databaseName: String
    public let recoveryDirectory: URL
    public let wasCancelled: Bool
    public var errorDescription: String? { "Restore did not complete. The planned database \(databaseName) may exist and is retained. Inspect the private recovery records at \(recoveryDirectory.path). Container commands may continue until their timeout. No database is automatically dropped." }
}

/// Owner-triggered logical exports and trusted restores against an already
/// running, explicitly selected local PostgreSQL container. No live-volume copy.
public struct PostgresBackup: Sendable {
    public static let archiveName = "database.pgdump"
    public static let manifestName = "CLOUDNEST_POSTGRES.json"
    public let executable: URL
    public let socket: URL
    public let protectedRoots: [URL]
    public let limits: PostgresBackupLimits
    public init(executable: URL, socket: URL, protectedRoots: [URL] = [], limits: PostgresBackupLimits = PostgresBackupLimits()) { self.executable = executable; self.socket = socket; self.protectedRoots = protectedRoots; self.limits = limits }
    public static func local(protectedRoots: [URL] = [], limits: PostgresBackupLimits = PostgresBackupLimits()) throws -> Self {
        let docker = try DockerImageBackup.local(protectedRoots: protectedRoots)
        return Self(executable: docker.executable, socket: docker.socket, protectedRoots: protectedRoots, limits: limits)
    }
    private static func identifier(_ value: String) -> Bool { value.utf8.count <= 63 && value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
    private static func reference(_ value: String) -> Bool { value.utf8.count <= 128 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil }
    private static func containerID(_ value: String) -> Bool { value.utf8.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    private func validate() throws {
        guard limits.maximumBytes > 0, limits.maximumBytes <= 100_000_000_000, limits.minimumFreeBytes >= 0,
              limits.metadataTimeout.isFinite, limits.metadataTimeout > 0, limits.metadataTimeout <= 60,
              limits.transferTimeout.isFinite, limits.transferTimeout > 0, limits.transferTimeout <= 3600 else { throw NestError.unsafePath("invalid PostgreSQL backup budget") }
        var binary = stat(), endpoint = stat()
        guard executable.isFileURL, socket.isFileURL, lstat(executable.path, &binary) == 0, binary.st_mode & S_IFMT == S_IFREG,
              binary.st_uid == 0 || binary.st_uid == getuid(), binary.st_mode & 0o022 == 0, binary.st_mode & 0o111 != 0,
              lstat(socket.path, &endpoint) == 0, endpoint.st_mode & S_IFMT == S_IFSOCK, endpoint.st_uid == 0 || endpoint.st_uid == getuid() else { throw NestError.unsafePath("existing local Docker executable or Unix socket is unavailable or unsafe") }
    }
    private func run(_ arguments: [String], session: PGSession, input: FileHandle? = nil, timeout: TimeInterval, maximumOutput: Int64, consume: (Data) throws -> Void = { _ in }) throws {
        try validate(); try Task.checkCancellation()
        let process = Process(), pipe = Pipe(), ended = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = ["--config", session.directory.path, "--host", "unix://" + socket.path] + arguments
        process.currentDirectoryURL = session.directory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "TMPDIR": session.directory.path]
        process.standardInput = input ?? FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        try process.run(); try? pipe.fileHandleForWriting.close(); defer { try? pipe.fileHandleForReading.close() }
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { process.terminate(); throw NestError.invalidResponse }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_048_576, alignment: 16); defer { buffer.deallocate() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout; var total: Int64 = 0, eof = false
        do {
            while !eof || process.isRunning {
                try Task.checkCancellation(); guard ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("PostgreSQL command exceeded its time budget") }
                if !eof {
                    var event = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0); let ready = poll(&event, 1, 25)
                    if ready < 0 && errno != EINTR { throw NestError.invalidResponse }
                    if ready > 0 {
                        let count = read(fd, buffer, 1_048_576)
                        if count > 0 { guard total <= maximumOutput - Int64(count) else { throw NestError.unsafePath("PostgreSQL output exceeded the byte budget") }; total += Int64(count); try autoreleasepool { try consume(Data(bytes: buffer, count: count)) } }
                        else if count == 0 { eof = true }
                        else if errno != EINTR && errno != EAGAIN { throw NestError.invalidResponse }
                    }
                } else { _ = ended.wait(timeout: .now() + .milliseconds(25)) }
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw NestError.unsafePath("PostgreSQL command failed. Check the selected container and peer/trust permissions locally. Any newly created database is retained; never drop an existing database automatically.") }
        } catch {
            if process.isRunning { process.terminate(); if ended.wait(timeout: .now() + 1) == .timedOut && process.isRunning { _ = kill(process.processIdentifier, SIGKILL); _ = ended.wait(timeout: .now() + 2) } }
            throw error
        }
    }
    private func inspect(_ reference: String, session: PGSession) throws -> String {
        var data = Data()
        try run(["container", "inspect", "--format", "{{.Id}} {{.State.Running}}", reference], session: session, timeout: limits.metadataTimeout, maximumOutput: 512) { data.append($0) }
        let values = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard values.count == 2, Self.containerID(String(values[0])), values[1] == "true" else { throw NestError.unsafePath("the explicitly selected container is not running or has an invalid ID") }; return String(values[0])
    }
    public func resolve(container reference: String) throws -> ResolvedPostgresContainer {
        guard Self.reference(reference) else { throw NestError.unsafePath("enter one container name or immutable ID") }; try validate()
        let session = try PGSession(); defer { session.clean() }
        return ResolvedPostgresContainer(reference: reference, id: try inspect(reference, session: session))
    }
    private func exec(_ tool: String, arguments: [String], container: ResolvedPostgresContainer, session: PGSession, input: FileHandle? = nil, timeout: TimeInterval, maximumOutput: Int64, consume: (Data) throws -> Void = { _ in }) throws {
        guard Self.reference(container.reference), Self.containerID(container.id), try inspect(container.id, session: session) == container.id else { throw NestError.sourceChanged }
        // env -i suppresses container PGPASSWORD, .pgpass/service configuration,
        // and host credentials. The fixed timeout bounds the engine-side exec
        // even if stopping the host Docker CLI does not cancel its child.
        var argv = ["exec", "--user", "postgres", "--workdir", "/"]
        if input != nil { argv.append("--interactive") }
        argv += [container.id, "/usr/bin/env", "-i", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "PGCONNECT_TIMEOUT=5", "PGPASSFILE=/dev/null", "PGSERVICEFILE=/dev/null", "PGOPTIONS=-c statement_timeout=\(Int(ceil(timeout * 1000))) -c lock_timeout=5000", "/usr/bin/timeout", "-k", "5", String(max(1, Int(ceil(timeout)))), tool] + arguments
        try run(argv, session: session, input: input, timeout: timeout, maximumOutput: maximumOutput, consume: consume)
    }
    private static func connection(_ role: String) -> [String] { ["--no-password", "--host", "/var/run/postgresql", "--username", role] }
    private func verifyCustom(_ fd: Int32, container: ResolvedPostgresContainer, session: PGSession) throws {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw NestError.invalidManifest }; var magic = [UInt8](repeating: 0, count: 5)
        guard read(fd, &magic, 5) == 5, Data(magic) == Data("PGDMP".utf8), lseek(fd, 0, SEEK_SET) == 0 else { throw NestError.invalidManifest }
        var bytes = 0
        try exec("pg_restore", arguments: ["--list", "--format=custom"], container: container, session: session, input: FileHandle(fileDescriptor: fd, closeOnDealloc: false), timeout: limits.metadataTimeout, maximumOutput: 8_388_608) { bytes += $0.count }
        guard bytes > 0, lseek(fd, 0, SEEK_SET) == 0 else { throw NestError.verificationFailed }
    }
    public func dump(container: ResolvedPostgresContainer, database: String, role: String, to destination: URL, onProgress: @Sendable (Int64) -> Void = { _ in }) throws -> PostgresBackupResult {
        guard Self.identifier(database), Self.identifier(role) else { throw NestError.unsafePath("database and role must be simple PostgreSQL identifiers of at most 63 ASCII characters") }; try validate()
        let parent = try PGFiles.directory(destination, protected: protectedRoots); defer { close(parent) }; try free(parent)
        if mkdirat(parent, ".cloudnest-recovery", 0o700) != 0 && errno != EEXIST { throw NestError.conflict }
        let recovery = openat(parent, ".cloudnest-recovery", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard recovery >= 0 else { throw NestError.unsafePath("private PostgreSQL staging unavailable") }; defer { close(recovery) }; try PGFiles.requirePrivate(recovery)
        let id = UUID(), name = "postgres-" + id.uuidString
        guard mkdirat(recovery, name, 0o700) == 0 else { throw NestError.conflict }
        let stage = openat(recovery, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard stage >= 0 else { throw NestError.sourceChanged }; defer { close(stage) }
        let archive = openat(stage, Self.archiveName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard archive >= 0 else { throw NestError.conflict }; defer { close(archive) }
        let session = try PGSession(); defer { session.clean() }
        var bytes: Int64 = 0, hash = SHA256(), nextProgress: TimeInterval = 0
        try exec("pg_dump", arguments: ["--format=custom", "--lock-wait-timeout=5000"] + Self.connection(role) + ["--dbname", database], container: container, session: session, timeout: limits.transferTimeout, maximumOutput: limits.maximumBytes) { data in
            try free(parent, needed: Int64(data.count)); try PGFiles.write(data, to: archive); hash.update(data: data); bytes += Int64(data.count); let now = ProcessInfo.processInfo.systemUptime; if now >= nextProgress { onProgress(bytes); nextProgress = now + 0.2 }
        }
        guard bytes > 5, fsync(archive) == 0 else { throw NestError.verificationFailed }
        let expected = hash.finalize().map { String(format: "%02x", $0) }.joined(), checked = try PGFiles.hash(archive, maximum: limits.maximumBytes, timeout: limits.transferTimeout)
        guard checked.0 == bytes, checked.1 == expected else { throw NestError.sourceChanged }
        let archiveIdentity = try PGFiles.identity(archive)
        try verifyCustom(archive, container: container, session: session)
        guard try PGFiles.identity(archive) == archiveIdentity else { throw NestError.sourceChanged }
        let manifest = PostgresBackupManifest(schemaVersion: 1, id: id, createdAt: Date(), containerReference: container.reference, containerID: container.id, database: database, role: role, archiveName: Self.archiveName, bytes: bytes, sha256: expected, permitsOriginalCleanup: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let metadata = openat(stage, Self.manifestName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard metadata >= 0 else { throw NestError.conflict }; defer { close(metadata) }
        try PGFiles.write(try encoder.encode(manifest), to: metadata); guard fsync(metadata) == 0 else { throw NestError.invalidResponse }
        let metadataIdentity = try PGFiles.identity(metadata)
        try PGFiles.inventory(stage); try PGFiles.requireNamed(stage, Self.archiveName, archiveIdentity); try PGFiles.requireNamed(stage, Self.manifestName, metadataIdentity)
        let selected = try PGFiles.directory(destination, protected: protectedRoots); defer { close(selected) }
        var first = stat(), second = stat(), staged = stat(), named = stat()
        guard fstat(parent, &first) == 0, fstat(selected, &second) == 0, first.st_dev == second.st_dev, first.st_ino == second.st_ino,
              fstat(stage, &staged) == 0, fstatat(recovery, name, &named, AT_SYMLINK_NOFOLLOW) == 0, staged.st_dev == named.st_dev, staged.st_ino == named.st_ino,
              fsync(stage) == 0, renameatx_np(recovery, name, parent, "PostgresBackup-" + id.uuidString, UInt32(RENAME_EXCL)) == 0 else { throw NestError.conflict }
        guard fsync(recovery) == 0, fsync(parent) == 0 else { throw NestError.unsafePath("PostgreSQL backup was published but synchronization was uncertain; retain and inspect it") }
        return PostgresBackupResult(directory: destination.appendingPathComponent("PostgresBackup-" + id.uuidString), manifest: manifest)
    }
    private func free(_ fd: Int32, needed: Int64 = 0) throws {
        var info = statfs(); guard fstatfs(fd, &info) == 0 else { throw NestError.invalidResponse }
        let capacity = Int64(clamping: info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
        guard !capacity.overflow, capacity.partialValue >= needed, capacity.partialValue - needed >= limits.minimumFreeBytes else { throw NestError.unsafePath("PostgreSQL backup needs additional free disk space") }
    }
    public static func review(directory: URL) throws -> PostgresBackupReview {
        let folder = try PGFiles.directory(directory, protected: []); defer { close(folder) }; try PGFiles.requirePrivate(folder); try PGFiles.inventory(folder)
        let fd = try PGFiles.regular(manifestName, parent: folder); defer { close(fd) }; let before = try PGFiles.identity(fd)
        guard before.size <= 16384 else { throw NestError.invalidManifest }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16385) ?? Data()
        guard data.count <= 16384, try PGFiles.identity(fd) == before else { throw NestError.sourceChanged }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; let manifest = try decoder.decode(PostgresBackupManifest.self, from: data)
        guard manifest.schemaVersion == 1, !manifest.permitsOriginalCleanup, manifest.archiveName == archiveName, manifest.bytes > 5, manifest.bytes <= 100_000_000_000,
              containerID(manifest.containerID), reference(manifest.containerReference), identifier(manifest.database), identifier(manifest.role), manifest.sha256.utf8.count == 64, manifest.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw NestError.invalidManifest }
        return PostgresBackupReview(directory: directory, manifest: manifest, manifestSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    public func planRestore(approved: PostgresBackupReview, container: ResolvedPostgresContainer, role: String) throws -> PostgresRestorePlan {
        guard Self.identifier(role), Self.containerID(container.id), Self.reference(container.reference) else { throw NestError.unsafePath("invalid restore role or container") }
        return PostgresRestorePlan(id: UUID(), container: container, role: role, review: approved)
    }
    public func restore(plan: PostgresRestorePlan) throws -> PostgresRestoreResult {
        try validate(); guard Self.identifier(plan.role), Self.containerID(plan.container.id) else { throw NestError.invalidManifest }
        let folder = try PGFiles.directory(plan.review.directory, protected: protectedRoots); defer { close(folder) }
        let current = try Self.review(directory: plan.review.directory); guard current.manifestSHA256 == plan.review.manifestSHA256, current.manifest.bytes <= limits.maximumBytes else { throw NestError.sourceChanged }
        let source = try PGFiles.regular(Self.archiveName, parent: folder); defer { close(source) }
        let initial = try PGFiles.hash(source, maximum: limits.maximumBytes, timeout: limits.transferTimeout)
        guard initial.0 == current.manifest.bytes, initial.1 == current.manifest.sha256 else { throw NestError.verificationFailed }
        let session = try PGSession()
        do {
        try free(session.fd, needed: current.manifest.bytes)
        let copy = openat(session.fd, "approved.pgdump", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard copy >= 0 else { throw NestError.conflict }; defer { close(copy) }
        guard lseek(source, 0, SEEK_SET) == 0 else { throw NestError.invalidResponse }
        let input = FileHandle(fileDescriptor: source, closeOnDealloc: false), copyDeadline = ProcessInfo.processInfo.systemUptime + limits.transferTimeout
        while let data = try autoreleasepool(invoking: { try input.read(upToCount: 1_048_576) }), !data.isEmpty { try Task.checkCancellation(); guard ProcessInfo.processInfo.systemUptime < copyDeadline else { throw NestError.unsafePath("PostgreSQL verification copy timed out") }; try free(session.fd, needed: Int64(data.count)); try PGFiles.write(data, to: copy); var info = stat(); guard fstat(copy, &info) == 0, info.st_size <= current.manifest.bytes else { throw NestError.sourceChanged } }
        guard fsync(copy) == 0 else { throw NestError.invalidResponse }
        let copied = try PGFiles.hash(copy, maximum: limits.maximumBytes, timeout: limits.transferTimeout)
        guard copied.0 == initial.0, copied.1 == initial.1 else { throw NestError.verificationFailed }
        let identity = try PGFiles.identity(copy); session.remember("approved.pgdump", identity)
        try verifyCustom(copy, container: plan.container, session: session)
        try PGFiles.requireNamed(session.fd, "approved.pgdump", identity)
        try session.record("01-create-planned.json", ["database": plan.databaseName, "containerID": plan.container.id, "role": plan.role, "sourceSHA256": current.manifest.sha256, "state": "creation-not-yet-confirmed"])
        try exec("createdb", arguments: Self.connection(plan.role) + ["--maintenance-db", "postgres", "--template", "template0", "--owner", plan.role, "--", plan.databaseName], container: plan.container, session: session, timeout: limits.metadataTimeout, maximumOutput: 1_048_576)
        try session.record("02-created.json", ["database": plan.databaseName, "state": "new-database-created-retain-if-interrupted"])
        try PGFiles.requireNamed(session.fd, "approved.pgdump", identity); guard lseek(copy, 0, SEEK_SET) == 0 else { throw NestError.invalidResponse }
        try exec("pg_restore", arguments: ["--format=custom", "--single-transaction", "--exit-on-error", "--no-owner", "--no-privileges", "--no-tablespaces"] + Self.connection(plan.role) + ["--dbname", plan.databaseName], container: plan.container, session: session, input: FileHandle(fileDescriptor: copy, closeOnDealloc: false), timeout: limits.transferTimeout, maximumOutput: 1_048_576)
        try PGFiles.requireNamed(session.fd, "approved.pgdump", identity)
        try session.record("03-restored.json", ["database": plan.databaseName, "state": "restore-command-completed", "containerID": plan.container.id])
        session.clean()
        return PostgresRestoreResult(databaseName: plan.databaseName, containerID: plan.container.id, recoveryDirectory: session.directory)
        } catch { throw PostgresRestoreFailure(databaseName: plan.databaseName, recoveryDirectory: session.directory, wasCancelled: error is CancellationError) }
    }
}

private enum PGFiles {
    static func requirePrivate(_ fd: Int32) throws {
        var info = stat(); guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw NestError.unsafePath("PostgreSQL staging must be owner-private") }
        guard let security = filesec_init() else { throw NestError.invalidResponse }; defer { filesec_free(security) }
        var secured = stat(), acl: Int32 = 0
        guard fstatx_np(fd, &secured, security) == 0, secured.st_ino == info.st_ino, secured.st_dev == info.st_dev, filesec_query_property(security, FILESEC_ACL, &acl) == 0, acl == 0 else { throw NestError.unsafePath("PostgreSQL staging has additional access permissions") }
    }
    static func directory(_ url: URL, protected: [URL]) throws -> Int32 {
        try FileSafety(protectedRoots: protected).validate(url, root: url)
        let fd = try FileSafety.openDirectory(url)
        var info = stat(), filesystem = statfs()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0, fstatfs(fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { close(fd); throw NestError.unsafePath("choose an owned local directory without shared write permissions") }
        guard let security = filesec_init() else { close(fd); throw NestError.invalidResponse }; defer { filesec_free(security) }
        var secured = stat(), acl: Int32 = 0
        guard fstatx_np(fd, &secured, security) == 0, secured.st_dev == info.st_dev, secured.st_ino == info.st_ino, filesec_query_property(security, FILESEC_ACL, &acl) == 0, acl == 0 else { close(fd); throw NestError.unsafePath("backup directory has additional access permissions") }; return fd
    }
    static func identity(_ fd: Int32) throws -> FileIdentity { var info = stat(); guard fstat(fd, &info) == 0 else { throw NestError.invalidResponse }; return FileSafety.identity(info) }
    static func regular(_ name: String, parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK); guard fd >= 0 else { throw NestError.unsafePath("PostgreSQL backup member unavailable") }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600, info.st_flags & UInt32(SF_DATALESS) == 0 else { close(fd); throw NestError.unsafePath("PostgreSQL backup must be a private owned regular file without links") }; return fd
    }
    static func requireNamed(_ parent: Int32, _ name: String, _ identity: FileIdentity) throws { let fd = try regular(name, parent: parent); defer { close(fd) }; guard try self.identity(fd) == identity else { throw NestError.sourceChanged } }
    static func write(_ data: Data, to fd: Int32) throws { try data.withUnsafeBytes { value in var offset = 0; while offset < value.count { try Task.checkCancellation(); let count = Darwin.write(fd, value.baseAddress!.advanced(by: offset), value.count - offset); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw NestError.invalidResponse }; offset += count } } }
    static func hash(_ fd: Int32, maximum: Int64, timeout: TimeInterval) throws -> (Int64, String) {
        let before = try identity(fd); guard before.size <= maximum, lseek(fd, 0, SEEK_SET) == 0 else { throw NestError.unsafePath("PostgreSQL archive exceeds byte budget") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false), deadline = ProcessInfo.processInfo.systemUptime + timeout; var total: Int64 = 0, hash = SHA256()
        while let data = try autoreleasepool(invoking: { try handle.read(upToCount: 1_048_576) }), !data.isEmpty { try Task.checkCancellation(); guard ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("PostgreSQL archive verification timed out") }; guard total <= maximum - Int64(data.count) else { throw NestError.sourceChanged }; hash.update(data: data); total += Int64(data.count) }
        guard try identity(fd) == before, total == before.size else { throw NestError.sourceChanged }; return (total, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func inventory(_ fd: Int32) throws {
        let duplicate = dup(fd); guard duplicate >= 0 else { throw NestError.invalidResponse }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw NestError.invalidResponse }; defer { closedir(stream) }; rewinddir(stream); var names = Set<String>(); errno = 0
        while let entry = readdir(stream) { let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }; if name != "." && name != ".." { names.insert(name); guard names.count <= 2 else { throw NestError.sourceChanged } }; errno = 0 }
        guard errno == 0, names == Set([PostgresBackup.archiveName, PostgresBackup.manifestName]) else { throw NestError.sourceChanged }
    }
}
private final class PGSession {
    let directory: URL
    let fd: Int32
    private var removable: [String: FileIdentity] = [:]
    init() throws {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw NestError.invalidResponse }; let rootPath = String(cString: path); free(path)
        // Preserve the OS-canonical /private path instead of URL normalization.
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC); guard parent >= 0 else { throw NestError.invalidResponse }
        for component in rootPath.split(separator: "/") { let next = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); close(parent); guard next >= 0 else { throw NestError.unsafePath("temporary directory unavailable") }; parent = next }
        defer { close(parent) }; let name = "cloudnest-postgres-" + UUID().uuidString
        guard mkdirat(parent, name, 0o700) == 0 else { throw NestError.conflict }
        let opened = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard opened >= 0 else { throw NestError.sourceChanged }
        do { try PGFiles.requirePrivate(opened) } catch { close(opened); throw error }
        let config = openat(opened, "config.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard config >= 0 else { close(opened); throw NestError.conflict }
        let configIdentity: FileIdentity
        do { try PGFiles.write(Data("{\"auths\":{}}\n".utf8), to: config); configIdentity = try PGFiles.identity(config); close(config) } catch { close(config); close(opened); throw error }
        fd = opened; directory = URL(fileURLWithPath: rootPath).appendingPathComponent(name); removable["config.json"] = configIdentity
    }
    deinit { close(fd) }
    func remember(_ name: String, _ identity: FileIdentity) { removable[name] = identity }
    func record(_ name: String, _ fields: [String: String]) throws {
        let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600); guard output >= 0 else { throw NestError.conflict }; defer { close(output) }
        try PGFiles.write(try JSONEncoder().encode(fields), to: output); guard fsync(output) == 0, fsync(fd) == 0 else { throw NestError.invalidResponse }
    }
    func clean() {
        for (name, expected) in removable { var info = stat(); if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileSafety.identity(info) == expected { _ = unlinkat(fd, name, 0) } }
        // rmdir only succeeds for this exact, empty job directory. A restore
        // journal or any unexpected member keeps the directory intact.
        var opened = stat(), named = stat()
        if fstat(fd, &opened) == 0, lstat(directory.path, &named) == 0, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino { _ = rmdir(directory.path) }
    }
}
