import Foundation
import CryptoKit
import Darwin

public struct ProjectCapsuleLimits: Sendable {
    public var maximumEntries = 9_900
    public var maximumBytes: Int64 = 2_000_000_000
    public init() {}
}
public struct ProjectCapsuleFile: Codable, Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String
    public let originalMode: UInt32
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let differsFromGitIndex: Bool?
}
public struct ProjectCapsuleExclusion: Codable, Sendable { public let path: String; public let reason: String }
public struct ProjectCapsuleGit: Codable, Sendable {
    public let commit: String
    public let branch: String?
    public let trackedChanges: [String]
    public let untrackedFiles: [String]
    public let includesWorkingTreeChanges: Bool
}
public struct ProjectCapsuleManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let projectName: String
    public let originalPath: String
    public let description: String
    public let createdAt: Date
    public let git: ProjectCapsuleGit
    public let files: [ProjectCapsuleFile]
    public let directories: [String]
    public let excluded: [ProjectCapsuleExclusion]
    public let dependencyManifests: [String]
    public let permitsOriginalCleanup: Bool
}
public struct ProjectCapsuleResult: Sendable {
    public let directory: URL
    public let manifest: ProjectCapsuleManifest
    public var manifestURL: URL { directory.appendingPathComponent("CLOUDNEST_PROJECT.json") }
}

private struct CapsuleEntry: Equatable {
    let path: String
    let identity: FileIdentity
    let mode: mode_t
    let directory: Bool
}
private struct CapsuleGitIndex: Equatable {
    let objectID: String
    let mode: String
}
private struct CapsuleInventory {
    var entries: [CapsuleEntry] = []
    var excluded: [ProjectCapsuleExclusion] = []
    var bytes: Int64 = 0
}

/// Creates a read-only working-tree snapshot in a user-selected local destination.
/// It never offloads, modifies or authorizes cleanup of the original repository.
public struct ProjectTimeCapsule: Sendable {
    public let protectedRoots: [URL]
    public let limits: ProjectCapsuleLimits
    public init(protectedRoots: [URL] = [], limits: ProjectCapsuleLimits = ProjectCapsuleLimits()) { self.protectedRoots = protectedRoots; self.limits = limits }
    private static let cacheNames: Set<String> = [".git", "node_modules", ".venv", "venv", ".build", "build", "dist", "deriveddata", "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".next", ".nuxt", ".gradle", "pods", "carthage", ".cloudnest-recovery", "target"]
    private static let privateNames: Set<String> = [".npmrc", ".pypirc", ".netrc", ".dev.vars", ".envrc", "token.json", "tokens.json", "access-token.json", "refresh-token.json", ".tokens.json", ".ds_store", "credentials.json", "credentials.yaml", "id_rsa", "id_ed25519", "authorized_keys", "known_hosts"]
    private static let privateExtensions: Set<String> = ["pem", "key", "p8", "p12", "pfx", "keystore", "mobileprovision"]
    private static let databaseExtensions: Set<String> = ["db", "sqlite", "sqlite3", "realm", "mdb", "lmdb", "rdb", "aof", "wal", "shm", "raw", "qcow", "qcow2", "vmdk", "vhd", "vhdx", "icloud"]
    private static let dependencyNames: Set<String> = ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "requirements.txt", "pyproject.toml", "poetry.lock", "uv.lock", "pipfile", "pipfile.lock", "cargo.toml", "cargo.lock", "go.mod", "go.sum", "package.swift", "package.resolved", "gemfile", "gemfile.lock", "dockerfile", "compose.yaml", "docker-compose.yml", "environment.yml"]
    private func validateSource(_ source: URL) throws {
        guard source.isFileURL, source.pathComponents.count > 2 else { throw NestError.unsafePath("select a local project folder") }
        let path = source.standardizedFileURL.path.lowercased()
        for root in protectedRoots {
            let blocked = root.standardizedFileURL.path.lowercased()
            guard path != blocked && !path.hasPrefix(blocked + "/") else { throw NestError.unsafePath("protected project folder") }
        }
        let roots = ["/system", "/library", "/applications", "/private", "/dev", "/usr", "/bin", "/sbin"]
        guard !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { throw NestError.unsafePath("system folder") }
        let blocked: Set<String> = ["library", "cloudstorage", ".trash", ".docker", ".git", ".cloudnest-recovery"]
        guard !source.pathComponents.map({ $0.lowercased() }).contains(where: { blocked.contains($0) || $0.hasPrefix("googledrive") || $0.hasPrefix("google drive") || $0.hasPrefix("onedrive") || $0 == "dropbox" || $0.hasSuffix(".app") || $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".photolibrary") }) else { throw NestError.unsafePath("system, cloud, repository-internal or package path") }
        let fd = try FileSafety.openDirectory(source); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw NestError.unsafePath("project is not fully local") }
        var marker = stat()
        guard fstatat(fd, ".git", &marker, AT_SYMLINK_NOFOLLOW) == 0,
              marker.st_mode & S_IFMT == S_IFDIR || marker.st_mode & S_IFMT == S_IFREG else { throw NestError.unsafePath("select a Git root with local repository metadata, not a symbolic-link marker") }
    }
    private static func exclusion(_ name: String, directory: Bool) -> String? {
        let lower = name.lowercased(), ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if cacheNames.contains(lower) || lower.hasSuffix(".dsym") { return "Repository internals or regenerable dependencies/build output" }
        if privateNames.contains(lower) || privateExtensions.contains(ext) || lower.hasPrefix("client_secret") || lower.hasPrefix("oauth") || lower.hasSuffix(".local.jsonc") || lower.hasSuffix(".private.json") { return "Credential, account configuration or private metadata" }
        if lower == ".env" || lower.hasPrefix(".env.") && ![".env.example", ".env.template", ".env.sample"].contains(lower) { return "Private environment configuration" }
        if databaseExtensions.contains(ext) || lower.hasSuffix("-wal") || lower.hasSuffix("-shm") { return "Database, virtual disk or cloud placeholder" }
        if lower.hasSuffix(".app") || lower.hasSuffix(".photoslibrary") || lower.hasSuffix(".photolibrary") || ["googledrive", "google drive", "onedrive"].contains(where: { lower.hasPrefix($0) }) || lower == "dropbox" { return "Application/library package or cloud folder" }
        return nil
    }
    private static func names(_ fd: Int32, budget: Int) throws -> [String] {
        let copy = dup(fd); guard copy >= 0 else { throw NestError.unsafePath("project folder unavailable") }
        guard let stream = fdopendir(copy) else { close(copy); throw NestError.unsafePath("project folder unreadable") }
        defer { closedir(stream) }
        var values: [String] = []
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw NestError.unsafePath("project enumeration failed") }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard values.count < budget else { throw NestError.unsafePath("project folder exceeds the snapshot entry budget") }
            values.append(name)
        }
        return values.sorted()
    }
    private func inventory(_ source: URL) throws -> CapsuleInventory {
        try validateSource(source)
        var result = CapsuleInventory(), keys = Set<String>(), visited = 0
        func walk(_ url: URL, relative: String, depth: Int) throws {
            guard depth <= 48 else { throw NestError.unsafePath("project nesting exceeds the snapshot budget") }
            let fd = try FileSafety.openDirectory(url); defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0 else { throw NestError.unsafePath("project folder unavailable") }
            let databaseMarkers: [String] = ["PG_VERSION", "WiredTiger", "ibdata1", "data.mdb"]
            if databaseMarkers.contains(where: { name in name.withCString { fstatat(fd, $0, &after, AT_SYMLINK_NOFOLLOW) == 0 } }) {
                if relative.isEmpty { throw NestError.unsafePath("project root is a live database storage folder") }
                result.excluded.append(ProjectCapsuleExclusion(path: relative, reason: "Database storage directory")); return
            }
            result.entries.append(CapsuleEntry(path: relative, identity: FileSafety.identity(before), mode: before.st_mode, directory: true))
            for name in try Self.names(fd, budget: min(100_000, max(1, limits.maximumEntries * 4))) {
                try Task.checkCancellation(); visited += 1
                guard visited <= min(100_000, limits.maximumEntries * 4), result.entries.count < min(9_900, max(1, limits.maximumEntries)) else { throw NestError.unsafePath("project exceeds the snapshot entry budget; choose a smaller project") }
                let path = relative.isEmpty ? name : relative + "/" + name
                _ = try FolderArchiveManifest.components(path)
                guard keys.insert(FolderArchiveManifest.key(path)).inserted else { throw NestError.unsafePath("case or Unicode project path conflict") }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NestError.sourceChanged }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                if let reason = Self.exclusion(name, directory: isDirectory) { result.excluded.append(ProjectCapsuleExclusion(path: path, reason: reason)); continue }
                let child = url.appendingPathComponent(name)
                let folded = child.standardizedFileURL.path.lowercased()
                if protectedRoots.contains(where: { let value = $0.standardizedFileURL.path.lowercased(); return folded == value || folded.hasPrefix(value + "/") }) { result.excluded.append(ProjectCapsuleExclusion(path: path, reason: "Protected folder")); continue }
                if info.st_mode & S_IFMT == S_IFLNK { result.excluded.append(ProjectCapsuleExclusion(path: path, reason: "Symbolic link; not followed")); continue }
                guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw NestError.unsafePath("project contains cloud placeholders") }
                if isDirectory { try walk(child, relative: path, depth: depth + 1) }
                else if info.st_mode & S_IFMT == S_IFREG {
                    let sum = result.bytes.addingReportingOverflow(info.st_size)
                    guard !sum.overflow, info.st_size >= 0, sum.partialValue <= limits.maximumBytes else { throw NestError.unsafePath("project exceeds the snapshot byte budget") }
                    result.bytes = sum.partialValue
                    result.entries.append(CapsuleEntry(path: path, identity: FileSafety.identity(info), mode: info.st_mode, directory: false))
                } else { result.excluded.append(ProjectCapsuleExclusion(path: path, reason: "Nonregular file; not read")) }
            }
            guard fstat(fd, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after) else { throw NestError.sourceChanged }
        }
        try walk(source, relative: "", depth: 0); return result
    }
    private static func git(_ arguments: [String], source: URL, temporaryDirectory: URL, allowExitOne: Bool = false) throws -> Data {
        try Task.checkCancellation()
        let id = UUID().uuidString, output = temporaryDirectory.appendingPathComponent(".git-output-" + id)
        let folder = try FileSafety.openDirectory(temporaryDirectory); defer { close(folder) }
        let fd = openat(folder, output.lastPathComponent, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NestError.unsafePath("cannot stage Git metadata") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close(); unlinkat(folder, output.lastPathComponent, 0) }
        let process = Process(), ended = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "submodule.recurse=false", "-C", source.path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_PAGER"] = "cat"
        environment["GIT_NO_LAZY_FETCH"] = "1"; environment["GIT_NO_REPLACE_OBJECTS"] = "1"; environment["GIT_ALLOW_PROTOCOL"] = ""; environment["GIT_PROTOCOL_FROM_USER"] = "0"
        process.environment = environment; process.standardOutput = file; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { throw NestError.unsafePath("Git is unavailable; install Apple's command line tools for Project Time Capsule") }
        let deadline = Date().addingTimeInterval(15)
        do {
            while ended.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                try Task.checkCancellation()
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_size <= 8 * 1024 * 1024, Date() < deadline else { throw NestError.unsafePath("Git metadata exceeded its time or size budget") }
            }
        } catch {
            if process.isRunning { process.terminate() }
            if ended.wait(timeout: .now() + .seconds(2)) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            throw error
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 || allowExitOne && process.terminationStatus == 1 else { throw NestError.unsafePath("select the root of a trusted, initialized Git working tree") }
        try file.seek(toOffset: 0)
        let data = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else { throw NestError.unsafePath("Git metadata exceeds its size budget") }
        return data
    }
    private static func gitState(source: URL, temporaryDirectory: URL) throws -> ProjectCapsuleGit {
        func text(_ arguments: [String], allowExitOne: Bool = false) throws -> String {
            let data = try git(arguments, source: source, temporaryDirectory: temporaryDirectory, allowExitOne: allowExitOne)
            guard var value = String(data: data, encoding: .utf8) else { throw NestError.invalidResponse }
            if value.hasSuffix("\n") { value.removeLast() }; return value
        }
        let top = try text(["rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: top).standardizedFileURL.path == source.standardizedFileURL.path,
              try text(["rev-parse", "--is-inside-work-tree"]) == "true" else { throw NestError.unsafePath("select the repository root, not a parent or nested folder") }
        let commit = try text(["rev-parse", "--verify", "HEAD"])
        guard commit.range(of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil else { throw NestError.invalidResponse }
        let branch = try text(["symbolic-ref", "--quiet", "--short", "HEAD"], allowExitOne: true)
        let changesData = try git(["diff-index", "--cached", "--name-status", "--no-renames", "--no-ext-diff", "--no-textconv", "-z", "HEAD", "--"], source: source, temporaryDirectory: temporaryDirectory)
        let parts = changesData.split(separator: 0, omittingEmptySubsequences: true)
        guard parts.count <= 40_000, parts.count % 2 == 0 else { throw NestError.unsafePath("too many staged Git changes") }
        var changes: [String] = []
        for index in stride(from: 0, to: parts.count, by: 2) { changes.append(String(decoding: parts[index], as: UTF8.self) + " " + String(decoding: parts[index + 1], as: UTF8.self)) }
        let deleted = try git(["ls-files", "--deleted", "-z"], source: source, temporaryDirectory: temporaryDirectory)
        changes += deleted.split(separator: 0, omittingEmptySubsequences: true).map { "Deleted working file: " + String(decoding: $0, as: UTF8.self) }
        return ProjectCapsuleGit(commit: commit, branch: branch.isEmpty ? nil : branch, trackedChanges: Array(Set(changes)).sorted(), untrackedFiles: [], includesWorkingTreeChanges: true)
    }
    private static func gitIndex(source: URL, temporaryDirectory: URL) throws -> [String: CapsuleGitIndex] {
        let data = try git(["ls-files", "--stage", "-z"], source: source, temporaryDirectory: temporaryDirectory)
        let entries = data.split(separator: 0, omittingEmptySubsequences: true)
        guard entries.count <= 20_000 else { throw NestError.unsafePath("Git index exceeds the project snapshot budget") }
        var result: [String: CapsuleGitIndex] = [:]
        for entry in entries {
            let text = String(decoding: entry, as: UTF8.self)
            guard let tab = text.firstIndex(of: "\t") else { throw NestError.invalidResponse }
            let fields = text[..<tab].split(separator: " ")
            guard fields.count == 3, fields[2] == "0", ["100644", "100755", "120000", "160000"].contains(String(fields[0])),
                  fields[1].range(of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil else { throw NestError.unsafePath("resolve Git index conflicts before creating a snapshot") }
            let path = String(text[text.index(after: tab)...]); _ = try FolderArchiveManifest.components(path)
            guard result[path] == nil else { throw NestError.invalidResponse }
            result[path] = CapsuleGitIndex(objectID: String(fields[1]), mode: String(fields[0]))
        }
        return result
    }
    private static func openParent(_ relative: String, rootFD: Int32) throws -> (Int32, String) {
        let parts = try FolderArchiveManifest.components(relative)
        var fd = dup(rootFD); guard fd >= 0 else { throw NestError.unsafePath("snapshot directory unavailable") }
        for component in parts.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd); guard next >= 0 else { throw NestError.unsafePath("snapshot path changed") }; fd = next
        }
        return (fd, parts.last!)
    }
    private static func placeholder(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        let lower = value.lowercased()
        return value.isEmpty || lower.hasPrefix("your_") || lower.hasPrefix("replace_") ||
            value.hasPrefix("${") && value.hasSuffix("}") || value.hasPrefix("<") && value.hasSuffix(">") ||
            value.hasPrefix("{{") && value.hasSuffix("}}")
    }
    private static func safeEnvironmentTemplate(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { return false }
            let key = String(line[..<separator]).lowercased(), value = String(line[line.index(after: separator)...])
            if ["key", "password", "secret", "token", "credential"].contains(where: key.contains), !placeholder(value) { return false }
        }
        return true
    }
    private static func secretFound(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let patterns = ["-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", "gh[pousr]_[A-Za-z0-9]{30,}", "github_pat_[A-Za-z0-9_]{30,}", "ya29\\.[A-Za-z0-9_-]{20,}", "1//[A-Za-z0-9_-]{30,}", "(?:AKIA|ASIA)[A-Z0-9]{16}", "AIza[A-Za-z0-9_-]{30,}", "xox[baprs]-[A-Za-z0-9-]{20,}", "sk-(?:proj-)?[A-Za-z0-9_-]{20,}", "https?://[^/\\s:]+:[^@\\s]+@"]
        if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return true }
        let assignment = try! NSRegularExpression(pattern: #"(?i)(?:api[_-]?key|password|client_secret|access_token|refresh_token|token)[\"']?\s*[:=]\s*[\"']([^\"'\r\n]+)[\"']"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in assignment.matches(in: text, range: range) {
            if let value = Range(match.range(at: 1), in: text), !placeholder(String(text[value])) { return true }
        }
        return false
    }
    private static func copy(_ entry: CapsuleEntry, sourceFD: Int32, destinationFD: Int32, index: CapsuleGitIndex?) throws -> ProjectCapsuleFile? {
        let (sourceParent, name) = try openParent(entry.path, rootFD: sourceFD); defer { close(sourceParent) }
        let inputFD = openat(sourceParent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard inputFD >= 0 else { throw NestError.sourceChanged }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true); defer { try? input.close() }
        var before = stat(), after = stat()
        guard fstat(inputFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG, FileSafety.identity(before) == entry.identity else { throw NestError.sourceChanged }
        let (destinationParent, target) = try openParent(entry.path, rootFD: destinationFD); defer { close(destinationParent) }
        let outputFD = openat(destinationParent, target, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw NestError.conflict }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true); defer { try? output.close() }
        var committed = false
        defer { if !committed { var own = stat(), named = stat(); if fstat(outputFD, &own) == 0, fstatat(destinationParent, target, &named, AT_SYMLINK_NOFOLLOW) == 0, own.st_dev == named.st_dev, own.st_ino == named.st_ino { unlinkat(destinationParent, target, 0) } } }
        if [".env.example", ".env.template", ".env.sample"].contains(name.lowercased()) {
            guard entry.identity.size <= 262_144 else { throw CapsuleSecretFound() }
            let template = try input.read(upToCount: 262_145) ?? Data()
            guard safeEnvironmentTemplate(template) else { throw CapsuleSecretFound() }
            try input.seek(toOffset: 0)
        }
        var hash = SHA256(), gitSHA1 = Insecure.SHA1(), gitSHA256 = SHA256(), copied: Int64 = 0, overlap = Data()
        let gitHeader = Data("blob \(entry.identity.size)\0".utf8)
        if index != nil { gitSHA1.update(data: gitHeader); gitSHA256.update(data: gitHeader) }
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
            var inspect = overlap; inspect.append(chunk)
            if secretFound(inspect) { throw CapsuleSecretFound() }
            overlap = inspect.suffix(4096)
            try output.write(contentsOf: chunk); hash.update(data: chunk)
            if index != nil { gitSHA1.update(data: chunk); gitSHA256.update(data: chunk) }
            copied += Int64(chunk.count); return true
        }) {}
        guard fstat(inputFD, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after), copied == entry.identity.size else { throw NestError.sourceChanged }
        try output.synchronize()
        // Keep staged snapshots owner-only while retaining the executable bit.
        guard fchmod(outputFD, (entry.mode & 0o100) != 0 ? 0o700 : 0o600) == 0 else { throw NestError.unsafePath("cannot preserve executable status") }
        try output.synchronize()
        committed = true
        let differs: Bool?
        if let index {
            let blob = index.objectID.count == 40 ? gitSHA1.finalize().map { String(format: "%02x", $0) }.joined() : gitSHA256.finalize().map { String(format: "%02x", $0) }.joined()
            differs = blob != index.objectID || (entry.mode & 0o100 != 0) != (index.mode == "100755")
        } else { differs = nil }
        return ProjectCapsuleFile(path: entry.path, bytes: copied, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), originalMode: UInt32(entry.mode & 0o777), modifiedSeconds: entry.identity.modifiedSeconds, modifiedNanos: entry.identity.modifiedNanos, differsFromGitIndex: differs)
    }
    public func create(source: URL, destination: URL, description: String = "", onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> ProjectCapsuleResult {
        try Task.checkCancellation(); try validateSource(source)
        guard limits.maximumBytes > 0, (1...9_900).contains(limits.maximumEntries) else { throw NestError.invalidResponse }
        try FileSafety(protectedRoots: protectedRoots).validate(destination, root: destination)
        guard !FileSafety.contains(source, destination) else { throw NestError.unsafePath("choose a snapshot destination outside the source repository") }
        let parent = try FileSafety.openDirectory(destination); defer { close(parent) }
        if mkdirat(parent, ".cloudnest-recovery", 0o700) != 0 && errno != EEXIST { throw NestError.unsafePath("cannot prepare private snapshot staging") }
        let recovery = openat(parent, ".cloudnest-recovery", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard recovery >= 0 else { throw NestError.unsafePath("snapshot staging unavailable") }; defer { close(recovery) }
        var recoveryInfo = stat()
        guard fstat(recovery, &recoveryInfo) == 0, recoveryInfo.st_uid == getuid(), recoveryInfo.st_mode & 0o077 == 0 else { throw NestError.unsafePath("snapshot staging must be private") }
        let id = UUID(), temporaryName = "capsule-" + id.uuidString
        guard mkdirat(recovery, temporaryName, 0o700) == 0 else { throw NestError.conflict }
        let stage = destination.appendingPathComponent(".cloudnest-recovery").appendingPathComponent(temporaryName)
        let stageFD = openat(recovery, temporaryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw NestError.unsafePath("cannot open snapshot staging") }; defer { close(stageFD) }
        var knownFiles: [(String, FileIdentity)] = [], knownDirectories: [String] = [], installed = false
        defer {
            if !installed {
                for (path, identity) in knownFiles.reversed() {
                    if let (fd, name) = try? Self.openParent(path, rootFD: stageFD) { var info = stat(); if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileSafety.identity(info) == identity { unlinkat(fd, name, 0) }; close(fd) }
                }
                for path in knownDirectories.reversed() { if let (fd, name) = try? Self.openParent(path, rootFD: stageFD) { unlinkat(fd, name, AT_REMOVEDIR); close(fd) } }
                unlinkat(recovery, temporaryName, AT_REMOVEDIR)
            }
        }
        let initial = try inventory(source)
        let git = try Self.gitState(source: source, temporaryDirectory: stage)
        let indexedPaths = try Self.gitIndex(source: source, temporaryDirectory: stage)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: destination.path)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > 512_000_000, initial.bytes < free - 512_000_000 else { throw NestError.unsafePath("insufficient destination space for a private snapshot and safety margin") }
        guard mkdirat(stageFD, "source", 0o700) == 0 else { throw NestError.conflict }; knownDirectories.append("source")
        let sourceFD = try FileSafety.openDirectory(source); defer { close(sourceFD) }
        let snapshotFD = openat(stageFD, "source", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard snapshotFD >= 0 else { throw NestError.unsafePath("snapshot unavailable") }; defer { close(snapshotFD) }
        for entry in initial.entries where entry.directory && !entry.path.isEmpty {
            let (fd, name) = try Self.openParent(entry.path, rootFD: snapshotFD); defer { close(fd) }
            guard mkdirat(fd, name, 0o700) == 0 else { throw NestError.conflict }; knownDirectories.append("source/" + entry.path)
        }
        var files: [ProjectCapsuleFile] = [], excluded = initial.excluded
        let entries = initial.entries.filter { !$0.directory }
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            do {
                if let copied = try autoreleasepool(invoking: { try Self.copy(entry, sourceFD: sourceFD, destinationFD: snapshotFD, index: indexedPaths[entry.path]) }) {
                    let (fd, name) = try Self.openParent(entry.path, rootFD: snapshotFD); defer { close(fd) }
                    var info = stat(); guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NestError.sourceChanged }
                    knownFiles.append(("source/" + entry.path, FileSafety.identity(info))); files.append(copied)
                }
            } catch is CapsuleSecretFound { excluded.append(ProjectCapsuleExclusion(path: entry.path, reason: "Potential credential detected in content; review the original separately")) }
            onProgress(index + 1, entries.count)
        }
        let final = try inventory(source)
        guard initial.entries == final.entries else { throw NestError.sourceChanged }
        let finalGit = try Self.gitState(source: source, temporaryDirectory: stage)
        guard git.commit == finalGit.commit, git.branch == finalGit.branch, git.trackedChanges == finalGit.trackedChanges,
              indexedPaths == (try Self.gitIndex(source: source, temporaryDirectory: stage)) else { throw NestError.sourceChanged }
        let originalIdentities = Dictionary(uniqueKeysWithValues: initial.entries.map { ($0.path, $0.identity) })
        for file in files {
            let (fd, name) = try Self.openParent(file.path, rootFD: sourceFD); defer { close(fd) }
            let payload = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard payload >= 0 else { throw NestError.sourceChanged }
            let input = FileHandle(fileDescriptor: payload, closeOnDealloc: true); defer { try? input.close() }
            let current = try FileSafety.snapshot(input)
            guard current.sha256 == file.sha256, current.identity.size == file.bytes,
                  current.identity == originalIdentities[file.path] else { throw NestError.sourceChanged }
            let (copiedParent, copiedName) = try Self.openParent(file.path, rootFD: snapshotFD); defer { close(copiedParent) }
            let copiedFD = openat(copiedParent, copiedName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard copiedFD >= 0 else { throw NestError.sourceChanged }
            let copiedInput = FileHandle(fileDescriptor: copiedFD, closeOnDealloc: true); defer { try? copiedInput.close() }
            let copiedSnapshot = try FileSafety.snapshot(copiedInput)
            guard copiedSnapshot.sha256 == file.sha256, copiedSnapshot.identity.size == file.bytes else { throw NestError.verificationFailed }
        }
        let manifest = ProjectCapsuleManifest(schemaVersion: 1, id: id, projectName: source.lastPathComponent, originalPath: source.path, description: String(description.prefix(4096)), createdAt: Date(), git: ProjectCapsuleGit(commit: git.commit, branch: git.branch, trackedChanges: git.trackedChanges + files.filter { $0.differsFromGitIndex == true }.map { "Raw working content or executable status differs from index: " + $0.path }, untrackedFiles: files.map(\.path).filter { indexedPaths[$0] == nil }, includesWorkingTreeChanges: true), files: files, directories: initial.entries.filter(\.directory).map(\.path).filter { !$0.isEmpty }, excluded: excluded, dependencyManifests: files.map(\.path).filter { Self.dependencyNames.contains(URL(fileURLWithPath: $0).lastPathComponent.lowercased()) }, permitsOriginalCleanup: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= 16 * 1024 * 1024 else { throw NestError.invalidManifest }
        let checklist = """
        # Project recovery checklist

        This capsule copies the selected working tree; it never authorizes removal of the original.
        Git commit: \(git.commit)
        Git branch: \(git.branch ?? "detached HEAD")
        Tracked working-tree changes: \(git.trackedChanges.count)

        1. Verify the CloudNest folder archive and restore into a new location.
        2. Inspect CLOUDNEST_PROJECT.json, especially excluded paths and dependencyManifests.
        3. Review source files and dependency scripts before running any code.
        4. Recreate dependencies using the project's recorded manifests and trusted tools.
        5. Restore secrets from your independent secret store; they are deliberately excluded.
        6. Reconnect your Git remote manually. Remote URLs and .git credentials were not copied.
        7. Original executable status is retained; original POSIX modes are recorded for review.
        8. Resource forks, ACLs, hard-link topology and arbitrary extended metadata are not a complete backup here.

        Potential credentials are detected conservatively, not exhaustively. Review the snapshot before upload.
        No container, dependency install, model inference or source script has been executed.
        """
        for (name, data) in [("CLOUDNEST_PROJECT.json", manifestData), ("RESTORE.md", Data(checklist.utf8))] {
            let fd = openat(stageFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NestError.conflict }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
            try file.write(contentsOf: data); try file.synchronize(); var info = stat(); guard fstat(fd, &info) == 0 else { throw NestError.unsafePath("cannot save snapshot metadata") }; knownFiles.append((name, FileSafety.identity(info)))
        }
        let expected = Set(knownFiles.map { $0.0 } + knownDirectories)
        var actual = Set<String>()
        func verifyNames(_ fd: Int32, prefix: String) throws {
            for name in try Self.names(fd, budget: 10_100) {
                try Task.checkCancellation()
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard actual.count <= 10_100 else { throw NestError.verificationFailed }
                var info = stat(); guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NestError.sourceChanged }
                actual.insert(path)
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw NestError.sourceChanged }; defer { close(child) }
                    try verifyNames(child, prefix: path)
                } else if info.st_mode & S_IFMT != S_IFREG { throw NestError.verificationFailed }
            }
        }
        try verifyNames(stageFD, prefix: "")
        guard expected == actual else { throw NestError.verificationFailed }
        try Task.checkCancellation()
        try FileSafety(protectedRoots: protectedRoots).validate(destination, root: destination)
        let currentParent = try FileSafety.openDirectory(destination); defer { close(currentParent) }
        var before = stat(), now = stat(), staged = stat(), namedStage = stat()
        guard fstat(parent, &before) == 0, fstat(currentParent, &now) == 0, before.st_dev == now.st_dev, before.st_ino == now.st_ino,
              fstat(stageFD, &staged) == 0, fstatat(recovery, temporaryName, &namedStage, AT_SYMLINK_NOFOLLOW) == 0,
              staged.st_dev == namedStage.st_dev, staged.st_ino == namedStage.st_ino else { throw NestError.unsafePath("snapshot destination moved") }
        let name = "ProjectCapsule-" + id.uuidString
        guard fsync(stageFD) == 0, renameatx_np(recovery, temporaryName, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw NestError.conflict }
        _ = fsync(parent); installed = true
        return ProjectCapsuleResult(directory: destination.appendingPathComponent(name), manifest: manifest)
    }
}
private struct CapsuleSecretFound: Error {}
