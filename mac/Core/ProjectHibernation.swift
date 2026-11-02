import Foundation
import CryptoKit
import Darwin

public struct ProjectMemoryCard: Sendable {
    public var title: String
    public let project: String
    public var body: String
    public let source: String
    public let category = "project"
    public let visibility = "private"
    public let archiveID: UUID
    public let remoteManifestID: String
}

/// A verified portable source snapshot plus an explicitly reviewed memory card.
/// Exclusions mean the original repository is NEVER authorized for deletion.
public struct ProjectHibernation: Sendable {
    public let protectedRoots: [URL]
    public let limits: ProjectCapsuleLimits
    public init(protectedRoots: [URL] = [], limits: ProjectCapsuleLimits = ProjectCapsuleLimits()) {
        self.protectedRoots = protectedRoots; self.limits = limits
    }
    public func create(source: URL, destination: URL, description: String = "", includeGitRecovery: Bool = false, historyAcknowledged: Bool = false, onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> ProjectCapsuleResult {
        if includeGitRecovery && !historyAcknowledged { throw NestError.unsafePath("Review and acknowledge private Git history before creating a recovery capsule") }
        try Self.requireInactive(source)
        let result = try ProjectTimeCapsule(protectedRoots: protectedRoots, limits: limits).create(source: source, destination: destination, description: description, onProgress: onProgress)
        try Self.requireInactive(source)
        if includeGitRecovery {
            _ = try ProjectGitRecovery.create(source: source, capsule: result, historyAcknowledged: historyAcknowledged, limits: limits)
            let file = try FileSafety.openDirectory(result.directory); defer { close(file) }
            let fd = openat(file, "RESTORE.md", O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NestError.unsafePath("cannot save Git recovery instructions") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw NestError.sourceChanged }
            try handle.write(contentsOf: Data(ProjectGitRecovery.restoreInstructions(result.manifest).utf8)); try handle.synchronize()
        }
        return result
    }
    /// Recover a completed local capsule after restart. Its metadata is untrusted
    /// until memoryCard binds its exact bytes to a verified archive manifest.
    public static func loadCapsule(at directory: URL, safety: FileSafety = FileSafety()) throws -> ProjectCapsuleResult {
        let file = try safety.openSource(directory.appendingPathComponent("CLOUDNEST_PROJECT.json"), root: directory)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 16 * 1024 * 1024 + 1), data.count <= 16 * 1024 * 1024 else { throw NestError.invalidManifest }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ProjectCapsuleManifest.self, from: data)
        guard manifest.schemaVersion == 1, !manifest.permitsOriginalCleanup,
              manifest.files.count <= 9_900, manifest.excluded.count <= 40_000,
              directory.lastPathComponent == "ProjectCapsule-" + manifest.id.uuidString else { throw NestError.invalidManifest }
        var seen = Set<String>()
        for entry in manifest.files {
            _ = try FolderArchiveManifest.components(entry.path)
            guard entry.bytes >= 0, entry.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  seen.insert(FolderArchiveManifest.key(entry.path)).inserted else { throw NestError.invalidManifest }
        }
        let result = ProjectCapsuleResult(directory: directory, manifest: manifest)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(ProjectGitRecovery.folderName).path) { guard try ProjectGitRecovery.load(capsule: result) != nil else { throw NestError.invalidManifest } }
        return result
    }
    public static func memoryCard(capsule: ProjectCapsuleResult, verifiedArchive job: FolderArchiveJob, decisions: String = "", nextAction: String = "") throws -> ProjectMemoryCard {
        guard job.state == .verified, job.source.standardizedFileURL == capsule.directory.standardizedFileURL,
              let archive = job.manifest, archive.id == job.id, let remote = job.remoteManifestID,
              remote.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw NestError.verificationFailed }
        try archive.validate()
        let manifest = capsule.manifest
        guard !manifest.permitsOriginalCleanup, manifest.files.count <= 9_900,
              manifest.git.commit.range(of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil else { throw NestError.invalidManifest }
        let safety = FileSafety()
        let manifestURL = capsule.manifestURL
        let handle = try safety.openSource(manifestURL, root: capsule.directory); defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: 16 * 1024 * 1024 + 1), bytes.count <= 16 * 1024 * 1024 else { throw NestError.invalidManifest }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(ProjectCapsuleManifest.self, from: bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        guard try encoder.encode(stored) == encoder.encode(manifest) else { throw NestError.sourceChanged }
        let files = Dictionary(uniqueKeysWithValues: archive.files.map { ($0.relativePath, $0.manifest) })
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard files["CLOUDNEST_PROJECT.json"]?.sha256 == digest, files["CLOUDNEST_PROJECT.json"]?.size == Int64(bytes.count),
              files["RESTORE.md"] != nil else { throw NestError.verificationFailed }
        for file in manifest.files {
            _ = try FolderArchiveManifest.components(file.path)
            guard let archived = files["source/" + file.path], archived.sha256 == file.sha256, archived.size == file.bytes else { throw NestError.verificationFailed }
        }
        let gitRecovery = try ProjectGitRecovery.validateArchive(capsule: capsule, archive: archive)
        let gitRecoveryNote = gitRecovery ? "Complete referenced history, older stashes/reflogs and exact staged index are included. Restore Git state using Hibernate Project after downloading this capsule. Hooks, config, remote URLs and credentials are not activated; reconnect trusted configuration manually." : "This is a working-tree snapshot, not a complete Git history backup. Remote addresses and .git credentials are omitted; reconnect manually."
        let dependencies = manifest.dependencyManifests.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        let names = Set(dependencies.map { $0.lowercased() })
        var stack: [String] = []
        if names.contains("package.json") { stack.append("JavaScript/TypeScript") }
        if !names.isDisjoint(with: ["requirements.txt", "pyproject.toml", "pipfile", "environment.yml"]) { stack.append("Python") }
        if names.contains("package.swift") { stack.append("Swift") }
        if names.contains("cargo.toml") { stack.append("Rust") }
        if names.contains("go.mod") { stack.append("Go") }
        if names.contains("gemfile") { stack.append("Ruby") }
        let safeName = bounded(clean(manifest.projectName, limit: 160), bytes: 160)
        let body = """
        # \(safeName)

        ## Verified archive
        CloudNest folder archive: \(job.id.uuidString)
        Drive manifest: \(remote)
        Archive state: verified. Original repository retained; original cleanup is not authorized.
        Included source/assets: \(manifest.files.count) files. Excluded paths: \(manifest.excluded.count); review CLOUDNEST_PROJECT.json before resuming.

        ## Project stack and dependencies
        Detected from manifest filenames only: \(stack.isEmpty ? "Review dependency manifests" : stack.joined(separator: ", ")).
        Dependency files: \(dependencies.prefix(24).map { bounded(clean($0, limit: 100), bytes: 100) }.joined(separator: ", ") + (dependencies.count > 24 ? " (additional files listed in the archive manifest)" : ""))

        ## Git state
        Commit: \(manifest.git.commit)
        Branch: \(bounded(clean(manifest.git.branch ?? "detached HEAD", limit: 160), bytes: 160))
        Tracked change records: \(manifest.git.trackedChanges.count). Included untracked files: \(manifest.git.untrackedFiles.count).
        \(gitRecoveryNote)

        ## Decisions — supplied by owner
        \(bounded(String(decisions.prefix(8_000)), bytes: 8_000))

        ## Restore and resume
        1. Find the archive above in Archive Library and verify a restore to a new empty destination.
        2. Read RESTORE.md and review all exclusions, source files and dependency scripts.
        3. If GIT_RECOVERY.json is present, choose Restore Git project from a reviewed capsule in Hibernate Project; it restores refs, stashes and staged state into a new directory without executing source code.
        4. Recover excluded secrets and trusted Git configuration separately, and rebuild dependencies with trusted tools.
        5. Original project remains available for omitted history, metadata or excluded assets.

        ## Next action — supplied by owner
        \(bounded(String(nextAction.prefix(4_000)), bytes: 4_000))
        """
        guard body.utf8.count <= 20_000 else { throw NestError.invalidResponse }
        return ProjectMemoryCard(title: "Resume " + safeName, project: "project-" + manifest.id.uuidString.lowercased(), body: body, source: "cloudnest:project-hibernation:" + manifest.id.uuidString, archiveID: job.id, remoteManifestID: remote)
    }
    private static func bounded(_ value: String, bytes: Int) -> String {
        var length = min(value.utf8.count, bytes)
        while length > 0 {
            if let clipped = String(bytes: value.utf8.prefix(length), encoding: .utf8) { return clipped }
            length -= 1
        }
        return ""
    }
    private static func clean(_ value: String, limit: Int) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "`" }.prefix(limit)))
    }
    public static func requireInactive(_ source: URL) throws {
        // Reuse the same bounded, fail-closed OS reader check as model parking.
        // A running model runtime also blocks this workflow conservatively.
        try ModelParking.requireInactive(source: source, isDirectory: true)
    }
}
