import Foundation
import CryptoKit
import Darwin

public struct ProjectGitReference: Codable, Sendable, Equatable {
    public let name: String
    public let objectID: String
    public let symbolicTarget: String?
}
public struct ProjectGitPayload: Codable, Sendable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
}
public struct ProjectGitRecoveryManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let capsuleID: UUID
    public let objectFormat: String
    public let head: String
    public let headReference: String?
    public let references: [ProjectGitReference]
    public let payloads: [ProjectGitPayload]
    public let historyMayContainPrivateData: Bool
    public let originalCleanupAuthorized: Bool
}
public struct ProjectGitRestoreResult: Sendable {
    public let directory: URL
    public let commit: String
    public let references: Int
    public let sourceFiles: Int
}

/// Portable Git recovery is opt-in: historical blobs may contain old credentials.
/// Config, remote addresses, hooks and external stores are never copied or activated.
public enum ProjectGitRecovery {
    public static let folderName = "git-recovery"
    public static let manifestName = "GIT_RECOVERY.json"
    private static let payloadNames: Set<String> = ["history.bundle", "staged.pack", "index.data", "index.entries", "exclude.data", "reflogs.data"]
    private static let maxMetadata = 8 * 1024 * 1024
    private static func oid(_ value: String) -> Bool { value.range(of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil }
    private static func reference(_ name: String) -> Bool {
        name.hasPrefix("refs/") && name.utf8.count <= 1024 && name.range(of: "^refs/[A-Za-z0-9._/-]+$", options: .regularExpression) != nil && !name.contains("..") && !name.contains("//") && !name.hasSuffix("/") && !name.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") })
    }
    private static func data(_ url: URL, maximum: Int) throws -> Data {
        let parent = try FileSafety.openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.invalidManifest }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size <= maximum else { throw NestError.invalidManifest }
        let bytes = try file.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw NestError.invalidManifest }; return bytes
    }
    private static func write(_ bytes: Data, to url: URL) throws {
        let parent = try FileSafety.openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NestError.conflict }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        try file.write(contentsOf: bytes); try file.synchronize()
    }
    private static func hash(_ url: URL, maximum: Int64) throws -> ProjectGitPayload {
        let parent = try FileSafety.openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.invalidManifest }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximum, before.st_flags & UInt32(SF_DATALESS) == 0 else { throw NestError.invalidManifest }
        var sha = SHA256(), bytes: Int64 = 0
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); bytes += Int64(chunk.count); guard bytes <= maximum else { throw NestError.invalidManifest }; sha.update(data: chunk) }
        guard fstat(fd, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after), bytes == before.st_size else { throw NestError.sourceChanged }
        return ProjectGitPayload(name: url.lastPathComponent, bytes: bytes, sha256: sha.finalize().map { String(format: "%02x", $0) }.joined())
    }
    @discardableResult private static func git(_ args: [String], at source: URL, scratch: URL, input: URL? = nil, output: URL? = nil, maximum: Int64 = Int64(maxMetadata), allowOne: Bool = false, anchor: Int32? = nil) throws -> Data {
        let cwd = try anchor.map { value -> Int32 in let fd = dup(value); guard fd >= 0 else { throw NestError.invalidResponse }; return fd } ?? FileSafety.openDirectory(source)
        defer { close(cwd) }
        let scratchFD = try anchor.map { value -> Int32 in let fd = dup(value); guard fd >= 0 else { throw NestError.invalidResponse }; return fd } ?? FileSafety.openDirectory(scratch)
        defer { close(scratchFD) }
        let name = output?.lastPathComponent ?? ".git-result-" + UUID().uuidString
        let fd = openat(scratchFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NestError.unsafePath("cannot stage private Git recovery output") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); if output == nil { unlinkat(scratchFD, name, 0) } }
        let inputFD: Int32
        if let input { let parent = try FileSafety.openDirectory(input.deletingLastPathComponent()); defer { close(parent) }; inputFD = openat(parent, input.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        else { inputFD = open("/dev/null", O_RDONLY | O_CLOEXEC) }
        guard inputFD >= 0 else { throw NestError.invalidManifest }; defer { close(inputFD) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw NestError.invalidResponse }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let changed: Int32
        if #available(macOS 26, *) { changed = posix_spawn_file_actions_addfchdir(&actions, cwd) }
        else { changed = posix_spawn_file_actions_addfchdir_np(&actions, cwd) }
        guard changed == 0, posix_spawn_file_actions_adddup2(&actions, inputFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { throw NestError.invalidResponse }
        let arguments = ["/usr/bin/git", "--no-pager", "--no-optional-locks", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.excludesFile=/dev/null", "-c", "submodule.recurse=false", "-c", "gc.auto=0", "-c", "pack.threads=1", "-c", "pack.windowMemory=16m", "-c", "core.deltaBaseCacheLimit=16m"] + args
        let environment = ["PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null", "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0", "GIT_NO_LAZY_FETCH=1", "GIT_NO_REPLACE_OBJECTS=1", "GIT_ALLOW_PROTOCOL=", "GIT_PROTOCOL_FROM_USER=0", "GIT_PAGER=cat"]
        let argv = arguments.map { strdup($0) } + [nil], envp = environment.map { strdup($0) } + [nil]
        defer { for value in argv + envp { if let value { free(value) } } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argv in envp.withUnsafeBufferPointer { env in posix_spawn(&pid, "/usr/bin/git", &actions, nil, argv.baseAddress!, env.baseAddress!) } }
        guard result == 0 else { throw NestError.unsafePath("Git recovery is unavailable; install Apple's command-line tools") }
        _ = setpriority(PRIO_PROCESS, id_t(pid), 10)
        var status: Int32 = 0
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while true {
                let ended = waitpid(pid, &status, WNOHANG)
                if ended == pid { break }
                guard ended == 0 || errno == EINTR else { throw NestError.invalidResponse }
                try Task.checkCancellation(); var info = stat()
                guard fstat(fd, &info) == 0, info.st_size <= maximum, ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("Git recovery exceeded its size or time budget") }
                usleep(50_000)
            }
        } catch {
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGTERM); let deadline = ProcessInfo.processInfo.systemUptime + 2
                while waitpid(pid, &status, WNOHANG) == 0 && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
                if waitpid(pid, &status, WNOHANG) == 0 { kill(pid, SIGKILL); _ = waitpid(pid, &status, 0) }
            }
            throw error
        }
        try Task.checkCancellation()
        let code = (status >> 8) & 0xff
        guard status & 0x7f == 0, code == 0 || allowOne && code == 1 else { throw NestError.unsafePath("Git recovery command " + (args.first ?? "unknown") + " failed (" + String(code) + "); source files were not changed") }
        try file.synchronize()
        var info = stat(); guard fstat(fd, &info) == 0, info.st_size <= maximum else { throw NestError.invalidManifest }
        if output != nil { return Data() }
        try file.seek(toOffset: 0); let bytes = try file.read(upToCount: maxMetadata + 1) ?? Data()
        guard bytes.count <= maxMetadata else { throw NestError.invalidManifest }; return bytes
    }
    private static func text(_ args: [String], at source: URL, scratch: URL, allowOne: Bool = false, anchor: Int32? = nil) throws -> String {
        guard var value = String(data: try git(args, at: source, scratch: scratch, allowOne: allowOne, anchor: anchor), encoding: .utf8) else { throw NestError.invalidManifest }
        if value.hasSuffix("\n") { value.removeLast() }; return value
    }
    private static func refs(at source: URL, scratch: URL, anchor: Int32? = nil) throws -> [ProjectGitReference] {
        let result = try text(["for-each-ref", "--format=%(objectname)%09%(refname)%09%(symref)"], at: source, scratch: scratch, anchor: anchor)
        return try result.split(separator: "\n").map { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, oid(fields[0]), reference(fields[1]), fields[2].isEmpty || reference(fields[2]) else { throw NestError.invalidManifest }
            return ProjectGitReference(name: fields[1], objectID: fields[0], symbolicTarget: fields[2].isEmpty ? nil : fields[2])
        }.sorted { $0.name < $1.name }
    }
    /// Inventory all repository internals without following links or external stores.
    private static func repositoryFingerprint(_ source: URL) throws -> String {
        let root = source.appendingPathComponent(".git")
        let fd = try FileSafety.openDirectory(root); defer { close(fd) }
        for name in ["commondir", "shallow", "worktrees", "modules", "objects/info/alternates", "objects/info/http-alternates", "info/sparse-checkout", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-apply", "rebase-merge", "BISECT_LOG", "reftable", "config.worktree"] {
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else { throw NestError.unsafePath("finish Git operations and use a complete standalone repository without submodules, worktrees, sparse or external object stores") }
        }
        var sha = SHA256(), count = 0, lines: [String] = [], failed = false
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in failed = true; return false }) else { throw NestError.invalidResponse }
        for case let url as URL in entries {
            try Task.checkCancellation(); count += 1
            guard count <= 100_000 else { throw NestError.unsafePath("Git recovery metadata exceeds the inspection budget") }
            var info = stat(); guard lstat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0, info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG else { throw NestError.unsafePath("Git metadata contains a link, placeholder or unsupported file") }
            let name = url.lastPathComponent
            guard !name.hasSuffix(".lock"), !name.hasSuffix(".promisor"), !name.hasPrefix("sharedindex.") else { throw NestError.unsafePath("close Git writers and disable split indexes/partial clones before recovery") }
            let relative = String(url.path.dropFirst(root.path.count)); lines.append("\(relative):\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)\n")
        }
        guard !failed else { throw NestError.unsafePath("Git metadata could not be fully inspected") }
        for line in lines.sorted() { sha.update(data: Data(line.utf8)) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func verifyWorkingTree(_ source: URL, capsule: ProjectCapsuleResult) throws {
        let sourceFD = try FileSafety.openDirectory(source); defer { close(sourceFD) }
        var before = stat(), after = stat(); guard fstat(sourceFD, &before) == 0 else { throw NestError.sourceChanged }
        var expectedFiles: [String: ProjectCapsuleFile] = [:]
        for file in capsule.manifest.files { guard expectedFiles.updateValue(file, forKey: file.path) == nil else { throw NestError.invalidManifest } }
        let expectedDirectories = Set(capsule.manifest.directories.filter { !$0.isEmpty })
        let exclusions = capsule.manifest.excluded.map(\.path)
        var actualFiles = Set<String>(), actualDirectories = Set<String>(), identities: [String: FileIdentity] = [:], visited = 0, failed = false
        guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in failed = true; return false }) else { throw NestError.invalidResponse }
        for case let url as URL in entries {
            try Task.checkCancellation(); visited += 1; guard visited <= 40_000 else { throw NestError.unsafePath("working-tree verification exceeds its entry budget") }
            let relative = String(url.path.dropFirst(source.path.count + 1))
            if exclusions.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { entries.skipDescendants(); continue }
            var info = stat(); guard lstat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw NestError.sourceChanged }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard expectedDirectories.contains(relative) else { throw NestError.sourceChanged }; actualDirectories.insert(relative)
            } else if info.st_mode & S_IFMT == S_IFREG {
                guard let expected = expectedFiles[relative] else { throw NestError.sourceChanged }
                let actual = try hash(url, maximum: 2_000_000_000)
                guard actual.bytes == expected.bytes, actual.sha256 == expected.sha256 else { throw NestError.sourceChanged }
                actualFiles.insert(relative)
            } else { throw NestError.sourceChanged }
            identities[relative] = FileSafety.identity(info)
        }
        guard !failed, actualFiles == Set(expectedFiles.keys), actualDirectories == expectedDirectories else { throw NestError.sourceChanged }
        for (relative, identity) in identities {
            var info = stat(); guard lstat(source.appendingPathComponent(relative).path, &info) == 0, FileSafety.identity(info) == identity else { throw NestError.sourceChanged }
        }
        guard fstat(sourceFD, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after) else { throw NestError.sourceChanged }
    }
    public static func create(source: URL, capsule: ProjectCapsuleResult, historyAcknowledged: Bool, limits: ProjectCapsuleLimits = ProjectCapsuleLimits()) throws -> ProjectGitRecoveryManifest {
        guard historyAcknowledged else { throw NestError.unsafePath("explicitly acknowledge that Git history and staged objects may contain private data before adding Git recovery") }
        guard source.standardizedFileURL.path == capsule.manifest.originalPath else { throw NestError.invalidManifest }
        try ProjectHibernation.requireInactive(source)
        let initial = try repositoryFingerprint(source)
        let root = capsule.directory.appendingPathComponent(folderName)
        guard mkdir(root.path, 0o700) == 0 else { throw NestError.conflict }
        let format = try text(["rev-parse", "--show-object-format"], at: source, scratch: root)
        guard ["sha1", "sha256"].contains(format) else { throw NestError.invalidManifest }
        guard try text(["config", "--local", "--get", "extensions.partialClone"], at: source, scratch: root, allowOne: true).isEmpty else { throw NestError.unsafePath("partial clones require a complete offline export before hibernation") }
        try git(["fsck", "--full", "--strict"], at: source, scratch: root)
        let references = try refs(at: source, scratch: root), head = try text(["rev-parse", "--verify", "HEAD"], at: source, scratch: root)
        let headReference = try text(["symbolic-ref", "--quiet", "HEAD"], at: source, scratch: root, allowOne: true)
        let shortBranch = try text(["symbolic-ref", "--quiet", "--short", "HEAD"], at: source, scratch: root, allowOne: true)
        guard head == capsule.manifest.git.commit, (shortBranch.isEmpty ? nil : shortBranch) == capsule.manifest.git.branch, headReference.isEmpty || reference(headReference) else { throw NestError.sourceChanged }
        let indexEntries = try git(["ls-files", "--stage", "-z"], at: source, scratch: root)
        var staged = Set<String>(), tracked = Set<String>()
        for raw in indexEntries.split(separator: 0) {
            let value = String(decoding: raw, as: UTF8.self); guard let tab = value.firstIndex(of: "\t") else { throw NestError.invalidManifest }
            let fields = value[..<tab].split(separator: " "), path = String(value[value.index(after: tab)...])
            guard fields.count == 3, ["100644", "100755"].contains(String(fields[0])), oid(String(fields[1])), fields[2] == "0" else { throw NestError.unsafePath("resolve index conflicts, links and submodules before Git recovery") }
            _ = try FolderArchiveManifest.components(path); tracked.insert(path); staged.insert(String(fields[1]))
            if FileManager.default.fileExists(atPath: source.appendingPathComponent(path).path), !capsule.manifest.files.contains(where: { $0.path == path }) { throw NestError.unsafePath("a tracked file was excluded from the source snapshot; preserve it separately before claiming Git working-state recovery") }
        }
        try write(indexEntries, to: root.appendingPathComponent("index.entries"))
        let originalIndex = source.appendingPathComponent(".git/index")
        let indexData: Data
        if FileManager.default.fileExists(atPath: originalIndex.path) { indexData = try data(originalIndex, maximum: maxMetadata) }
        else {
            guard indexEntries.isEmpty else { throw NestError.sourceChanged }
            var empty = Data([0x44, 0x49, 0x52, 0x43, 0, 0, 0, 2, 0, 0, 0, 0])
            empty.append(format == "sha1" ? Data(Insecure.SHA1.hash(data: empty)) : Data(SHA256.hash(data: empty))); indexData = empty
        }
        try write(indexData, to: root.appendingPathComponent("index.data"))
        let exclude = source.appendingPathComponent(".git/info/exclude")
        try write(FileManager.default.fileExists(atPath: exclude.path) ? data(exclude, maximum: 262_144) : Data(), to: root.appendingPathComponent("exclude.data"))
        var reflogs: [String: Data] = [:], reflogBytes = 0
        let logs = source.appendingPathComponent(".git/logs")
        if FileManager.default.fileExists(atPath: logs.path) {
            guard let walk = FileManager.default.enumerator(at: logs, includingPropertiesForKeys: nil) else { throw NestError.invalidResponse }
            for case let url as URL in walk {
                var info = stat(); guard lstat(url.path, &info) == 0 else { throw NestError.sourceChanged }
                if info.st_mode & S_IFMT == S_IFDIR { continue }
                let name = String(url.path.dropFirst(logs.path.count + 1))
                guard name == "HEAD" || reference(name), reflogs.count < 20_000 else { throw NestError.invalidManifest }
                let bytes = try data(url, maximum: maxMetadata); reflogBytes += bytes.count
                guard reflogBytes <= maxMetadata else { throw NestError.unsafePath("Git reflogs exceed the recovery metadata budget") }
                reflogs[name] = bytes
            }
        }
        try write(JSONEncoder().encode(reflogs), to: root.appendingPathComponent("reflogs.data"))
        let objectList = root.appendingPathComponent(".object-input-" + UUID().uuidString)
        try write(Data((staged.isEmpty ? "" : staged.sorted().joined(separator: "\n") + "\n").utf8), to: objectList); defer { unlink(objectList.path) }
        try git(["pack-objects", "--stdout"], at: source, scratch: root, input: objectList, output: root.appendingPathComponent("staged.pack"), maximum: limits.maximumBytes)
        try git(["bundle", "create", "-", "--all", "--reflog", "HEAD"], at: source, scratch: root, output: root.appendingPathComponent("history.bundle"), maximum: limits.maximumBytes)
        try git(["bundle", "verify", root.appendingPathComponent("history.bundle").path], at: source, scratch: root)
        let payloads = try payloadNames.sorted().map { try hash(root.appendingPathComponent($0), maximum: limits.maximumBytes) }
        let total = payloads.reduce(Int64(0)) { $0 + $1.bytes }
        try verifyWorkingTree(source, capsule: capsule)
        guard total <= limits.maximumBytes, try repositoryFingerprint(source) == initial,
              try git(["ls-files", "--stage", "-z"], at: source, scratch: root) == indexEntries,
              try refs(at: source, scratch: root) == references else { throw NestError.sourceChanged }
        try ProjectHibernation.requireInactive(source)
        let manifest = ProjectGitRecoveryManifest(schemaVersion: 1, capsuleID: capsule.manifest.id, objectFormat: format, head: head, headReference: headReference.isEmpty ? nil : headReference, references: references, payloads: payloads, historyMayContainPrivateData: true, originalCleanupAuthorized: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let encoded = try encoder.encode(manifest); guard encoded.count <= maxMetadata else { throw NestError.invalidManifest }
        try write(encoded, to: capsule.directory.appendingPathComponent(manifestName))
        return manifest
    }
    public static func load(capsule: ProjectCapsuleResult) throws -> ProjectGitRecoveryManifest? {
        let url = capsule.directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let manifest = try JSONDecoder().decode(ProjectGitRecoveryManifest.self, from: data(url, maximum: maxMetadata))
        guard manifest.schemaVersion == 1, manifest.capsuleID == capsule.manifest.id, ["sha1", "sha256"].contains(manifest.objectFormat), oid(manifest.head), manifest.head == capsule.manifest.git.commit,
              manifest.headReference.map(reference) ?? true, manifest.historyMayContainPrivateData, !manifest.originalCleanupAuthorized,
              Set(manifest.payloads.map(\.name)) == payloadNames, manifest.payloads.count == payloadNames.count,
              manifest.references.count <= 20_000, Set(manifest.references.map(\.name)).count == manifest.references.count,
              manifest.references.allSatisfy({ reference($0.name) && oid($0.objectID) && ($0.symbolicTarget.map(reference) ?? true) }) else { throw NestError.invalidManifest }
        guard manifest.payloads.allSatisfy({ $0.bytes >= 0 && $0.bytes <= 2_000_000_000 }), manifest.payloads.reduce(Int64(0), { $0 + $1.bytes }) <= 2_000_000_000,
              Set(try FileManager.default.contentsOfDirectory(atPath: capsule.directory.appendingPathComponent(folderName).path)) == payloadNames else { throw NestError.invalidManifest }
        for payload in manifest.payloads {
            let actual = try hash(capsule.directory.appendingPathComponent(folderName).appendingPathComponent(payload.name), maximum: 2_000_000_000)
            guard actual.bytes == payload.bytes, actual.sha256 == payload.sha256 else { throw NestError.verificationFailed }
        }
        return manifest
    }
    public static func validateArchive(capsule: ProjectCapsuleResult, archive: FolderArchiveManifest) throws -> Bool {
        guard let recovery = try load(capsule: capsule) else { return false }
        let files = Dictionary(uniqueKeysWithValues: archive.files.map { ($0.relativePath, $0.manifest) })
        let metadata = try hash(capsule.directory.appendingPathComponent(manifestName), maximum: Int64(maxMetadata))
        guard files[manifestName]?.sha256 == metadata.sha256, files[manifestName]?.size == metadata.bytes else { throw NestError.verificationFailed }
        for payload in recovery.payloads {
            guard files[folderName + "/" + payload.name]?.sha256 == payload.sha256, files[folderName + "/" + payload.name]?.size == payload.bytes else { throw NestError.verificationFailed }
        }
        return true
    }
    public static func restoreInstructions(_ manifest: ProjectCapsuleManifest) -> String {
        let dependencies = Set(manifest.dependencyManifests.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
        var notes = ["\n\n## Portable Git recovery (supersedes the snapshot-only Git note above)",
                     "GIT_RECOVERY.json and git-recovery/ contain referenced history, reflogs/older stashes, staged-only blobs and exact index state. They may include sensitive historical data. Keep this capsule private.",
                     "Download/verify the complete capsule in Archive Library, then choose Restore Git project from a reviewed capsule in Hibernate Project. Choose an unused project destination. CloudNest verifies refs, index and file hashes without checkout, hooks, filters, dependency scripts or network access.",
                     "Inspect git status and git stash list after restore. Original config/remotes/hooks are intentionally not activated. Reconnect trusted remotes, credentials, text-conversion settings and reviewed filters manually. Excluded private working files are not reconstructed from historical versions.",
                     "Review every dependency manifest and install script before running any command. The following are owner-run suggestions, not commands executed by CloudNest:"]
        if dependencies.contains("package-lock.json") { notes.append("Node: npm ci --ignore-scripts initially; review before enabling any required installation scripts.") }
        else if dependencies.contains("pnpm-lock.yaml") { notes.append("Node: use the project's recorded pnpm version and frozen lockfile, initially with install scripts disabled.") }
        else if dependencies.contains("yarn.lock") { notes.append("Node: use the project's recorded Yarn version and immutable/frozen lockfile settings; review scripts first.") }
        if !dependencies.isDisjoint(with: ["requirements.txt", "pyproject.toml", "poetry.lock", "uv.lock", "pipfile.lock"]) { notes.append("Python: create a fresh virtual environment; use the recorded tool and reviewed lockfile. Never reuse an archived environment or blindly install unpinned requirements.") }
        if dependencies.contains("package.swift") { notes.append("Swift: review Package.swift and Package.resolved, then resolve/build using the recorded Swift toolchain. Package plugins may execute code.") }
        if dependencies.contains("cargo.lock") { notes.append("Rust: review Cargo.toml/build scripts, then use the recorded toolchain and --locked dependency resolution.") }
        if dependencies.contains("go.mod") { notes.append("Go: review go.mod/go.sum and use the recorded Go version before downloading modules/building.") }
        notes.append("Original repository cleanup remains unauthorized. Git history recovery does not back up excluded private working files, external services, complete POSIX metadata or live databases.")
        return notes.joined(separator: "\n\n") + "\n"
    }
    /// Restore only to a new project name under a user-selected local parent.
    /// Failed private staging is retained for review instead of recursively erased.
    public static func restore(capsule: ProjectCapsuleResult, destination: URL, historyAcknowledged: Bool, safety: FileSafety = FileSafety()) throws -> ProjectGitRestoreResult {
        guard historyAcknowledged, let manifest = try load(capsule: capsule) else { throw NestError.unsafePath("choose a complete Git recovery capsule and acknowledge its private history") }
        try safety.validate(destination, root: destination)
        try ProjectHibernation.requireInactive(destination)
        let nameParts = try FolderArchiveManifest.components(capsule.manifest.projectName)
        guard nameParts.count == 1 else { throw NestError.invalidManifest }
        let parent = try FileSafety.openDirectory(destination); defer { close(parent) }
        let target = destination.appendingPathComponent(capsule.manifest.projectName)
        try safety.validateDestination(target, root: destination)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NestError.conflict }
        let required = capsule.manifest.files.reduce(Int64(0)) { $0 + max(0, min(2_000_000_001, $1.bytes)) }
        let free = (try FileManager.default.attributesOfFileSystem(forPath: destination.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard required <= 2_000_000_000, free > required + manifest.payloads.reduce(Int64(0), { $0 + $1.bytes }) + 512_000_000 else { throw NestError.unsafePath("insufficient disk space for verified project recovery") }
        let stageName = ".cloudnest-project-restore-" + UUID().uuidString, stage = destination.appendingPathComponent(stageName)
        guard mkdirat(parent, stageName, 0o700) == 0 else { throw NestError.conflict }
        let stageFD = try FileSafety.openDirectory(stage); defer { close(stageFD) }
        do {
        func parts(_ relative: String) throws -> [String] {
            let values = try FolderArchiveManifest.components(relative)
            guard !values.contains(where: { $0.lowercased() == ".git" }) else { throw NestError.invalidManifest }
            return values
        }
        func directory(_ values: [String], create: Bool) throws -> Int32 {
            var fd = dup(stageFD); guard fd >= 0 else { throw NestError.invalidResponse }
            do {
                for value in values {
                    if create && mkdirat(fd, value, 0o700) != 0 && errno != EEXIST { throw NestError.conflict }
                    let next = openat(fd, value, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); close(fd)
                    guard next >= 0 else { throw NestError.unsafePath("restore directory changed") }; fd = next
                }
                return fd
            } catch { close(fd); throw error }
        }
        guard capsule.manifest.files.count <= 9_900, capsule.manifest.directories.count <= 9_900 else { throw NestError.invalidManifest }
        for path in capsule.manifest.directories where !path.isEmpty { let fd = try directory(parts(path), create: true); close(fd) }
        var names = Set<String>()
        for entry in capsule.manifest.files {
            try Task.checkCancellation()
            let values = try parts(entry.path)
            guard names.insert(FolderArchiveManifest.key(entry.path)).inserted, entry.bytes >= 0, entry.bytes <= 2_000_000_000,
                  entry.originalMode <= 0o777, (0..<1_000_000_000).contains(entry.modifiedNanos) else { throw NestError.invalidManifest }
            let input = try safety.openSource(capsule.directory.appendingPathComponent("source").appendingPathComponent(entry.path), root: capsule.directory)
            defer { try? input.close() }
            let folder = try directory(Array(values.dropLast()), create: false); defer { close(folder) }
            let fd = openat(folder, values.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, entry.originalMode & 0o100 != 0 ? 0o700 : 0o600)
            guard fd >= 0 else { throw NestError.conflict }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? output.close() }
            var sha = SHA256(), copied: Int64 = 0
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation(); copied += Int64(bytes.count)
                guard copied <= entry.bytes else { throw NestError.verificationFailed }
                sha.update(data: bytes); try output.write(contentsOf: bytes)
            }
            guard copied == entry.bytes, sha.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else { throw NestError.verificationFailed }
            var times = [timespec(tv_sec: Int(entry.modifiedSeconds), tv_nsec: Int(entry.modifiedNanos)), timespec(tv_sec: Int(entry.modifiedSeconds), tv_nsec: Int(entry.modifiedNanos))]
            guard futimens(fd, &times) == 0 else { throw NestError.unsafePath("could not restore project timestamps") }
            try output.synchronize()
        }
        let recovery = capsule.directory.appendingPathComponent(folderName)
        let emptyTemplate = stage.appendingPathComponent(".cloudnest-empty-template-" + UUID().uuidString)
        guard mkdir(emptyTemplate.path, 0o700) == 0 else { throw NestError.conflict }
        try git(["init", "--quiet", "--object-format=" + manifest.objectFormat, "--template=" + emptyTemplate.path], at: stage, scratch: stage, anchor: stageFD)
        guard rmdir(emptyTemplate.path) == 0 else { throw NestError.conflict }
        // No original configuration, hooks, includes, remote URLs or credential helpers.
        try git(["config", "--local", "core.hooksPath", "/dev/null"], at: stage, scratch: stage, anchor: stageFD)
        try git(["config", "--local", "core.fsmonitor", "false"], at: stage, scratch: stage, anchor: stageFD)
        try git(["config", "--local", "core.autocrlf", "false"], at: stage, scratch: stage, anchor: stageFD)
        try git(["config", "--local", "gc.auto", "0"], at: stage, scratch: stage, anchor: stageFD)
        try git(["bundle", "verify", "/dev/stdin"], at: stage, scratch: stage, input: recovery.appendingPathComponent("history.bundle"), anchor: stageFD)
        try git(["bundle", "unbundle", "/dev/stdin"], at: stage, scratch: stage, input: recovery.appendingPathComponent("history.bundle"), anchor: stageFD)
        try git(["index-pack", "--stdin", "--strict"], at: stage, scratch: stage, input: recovery.appendingPathComponent("staged.pack"), anchor: stageFD)
        let direct = manifest.references.filter { $0.symbolicTarget == nil }
        let instructions = stage.appendingPathComponent(".ref-input-" + UUID().uuidString)
        try write(Data(direct.map { "create " + $0.name + " " + $0.objectID + "\n" }.joined().utf8), to: instructions)
        defer { unlink(instructions.path) }
        try git(["update-ref", "--stdin"], at: stage, scratch: stage, input: instructions, anchor: stageFD)
        for ref in manifest.references { if let target = ref.symbolicTarget { try git(["symbolic-ref", ref.name, target], at: stage, scratch: stage, anchor: stageFD) } }
        if let head = manifest.headReference { try git(["symbolic-ref", "HEAD", head], at: stage, scratch: stage, anchor: stageFD) }
        else { try git(["update-ref", "--no-deref", "HEAD", manifest.head], at: stage, scratch: stage, anchor: stageFD) }
        let gitRoot = stage.appendingPathComponent(".git")
        let existingIndex = gitRoot.appendingPathComponent("index")
        guard !FileManager.default.fileExists(atPath: existingIndex.path) else { throw NestError.conflict }
        try write(data(recovery.appendingPathComponent("index.data"), maximum: maxMetadata), to: existingIndex)
        let info = gitRoot.appendingPathComponent("info"); guard mkdir(info.path, 0o700) == 0 || errno == EEXIST else { throw NestError.conflict }
        try write(data(recovery.appendingPathComponent("exclude.data"), maximum: 262_144), to: info.appendingPathComponent("exclude"))
        let logs = try JSONDecoder().decode([String: Data].self, from: data(recovery.appendingPathComponent("reflogs.data"), maximum: maxMetadata * 2))
        guard logs.count <= 20_000 else { throw NestError.invalidManifest }
        for (name, bytes) in logs {
            guard name == "HEAD" || reference(name), bytes.count <= maxMetadata else { throw NestError.invalidManifest }
            let parts = name.split(separator: "/").map(String.init)
            var path = gitRoot.appendingPathComponent("logs")
            for component in parts.dropLast() { path.appendPathComponent(component) }
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = path.appendingPathComponent(parts.last!)
            // update-ref generated local logs in this entirely new private stage.
            if FileManager.default.fileExists(atPath: file.path) { let fd = open(file.path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw NestError.conflict }; let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
            else { try write(bytes, to: file) }
        }
        try git(["fsck", "--full", "--strict"], at: stage, scratch: stage, anchor: stageFD)
        guard try refs(at: stage, scratch: stage, anchor: stageFD) == manifest.references,
              try text(["rev-parse", "HEAD"], at: stage, scratch: stage, anchor: stageFD) == manifest.head,
              try git(["ls-files", "--stage", "-z"], at: stage, scratch: stage, anchor: stageFD) == data(recovery.appendingPathComponent("index.entries"), maximum: maxMetadata) else { throw NestError.verificationFailed }
        // Remove only our known generated instruction file before publication.
        guard unlink(instructions.path) == 0, fsync(stageFD) == 0 else { throw NestError.unsafePath("cannot finalize project recovery") }
        try ProjectHibernation.requireInactive(destination)
        let current = try FileSafety.openDirectory(destination); defer { close(current) }
        var first = stat(), second = stat(), owned = stat(), named = stat()
        guard fstat(parent, &first) == 0, fstat(current, &second) == 0, first.st_dev == second.st_dev, first.st_ino == second.st_ino,
              fstat(stageFD, &owned) == 0, fstatat(parent, stageName, &named, AT_SYMLINK_NOFOLLOW) == 0, owned.st_dev == named.st_dev, owned.st_ino == named.st_ino else { throw NestError.sourceChanged }
        guard renameatx_np(parent, stageName, parent, capsule.manifest.projectName, UInt32(RENAME_EXCL)) == 0 else { throw NestError.conflict }
        guard fsync(parent) == 0 else { throw NestError.unsafePath("project was restored but its parent could not be synchronized; keep the restored copy") }
        return ProjectGitRestoreResult(directory: target, commit: manifest.head, references: manifest.references.count, sourceFiles: capsule.manifest.files.count)
        } catch {
            if error is CancellationError { throw error }
            throw NestError.unsafePath("Project recovery did not finish. Private staging was retained at " + stage.path + ". No original or existing project was replaced. " + error.localizedDescription)
        }
    }
}
