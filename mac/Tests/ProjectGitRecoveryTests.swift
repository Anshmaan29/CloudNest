import Testing
import Foundation
import Darwin
@testable import CloudNestCore

private struct GitRecoveryFixture {
    let f: Fixture
    let project: URL
    let snapshots: URL
    init() throws {
        f = try Fixture(); project = f.base.appendingPathComponent("RecoverableProject"); snapshots = f.base.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try write("tracked.txt", "base\n"); try write("deleted.txt", "keep index but remove working file\n")
        try write("run.sh", "#!/bin/sh\nexit 0\n"); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.appendingPathComponent("run.sh").path)
        try write(".gitignore", ".env\n"); try write("package.json", "{\"name\":\"generated-fixture\"}\n")
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["add", "."]); _ = try git(["commit", "-qm", "Generated fixture baseline"])
        _ = try git(["checkout", "-qb", "feature"]); _ = try git(["tag", "fixture-tag"])
        try write("tracked.txt", "older stash\n"); _ = try git(["stash", "push", "-qm", "older fixture stash"])
        try write("tracked.txt", "newer stash\n"); _ = try git(["stash", "push", "-qm", "newer fixture stash"])
        try write("tracked.txt", "staged bytes\n"); _ = try git(["add", "tracked.txt"]); try write("tracked.txt", "unstaged bytes\n")
        try write("staged-new.txt", "index-only blob\n"); _ = try git(["add", "staged-new.txt"]); try write("staged-new.txt", "different working bytes\n")
        try write("notes.md", "untracked important note\n"); try write(".env", "OWNER_PRIVATE_CONFIGURATION=generated-private-fixture\n")
        try FileManager.default.removeItem(at: project.appendingPathComponent("deleted.txt"))
    }
    func write(_ path: String, _ body: String) throws { try Data(body.utf8).write(to: project.appendingPathComponent(path)) }
    @discardableResult func git(_ args: [String], at directory: URL? = nil) throws -> Data {
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.excludesFile=/dev/null", "-C", (directory ?? project).path] + args
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Generated Fixture", "GIT_COMMITTER_NAME": "Generated Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NestError.invalidResponse }; return bytes
    }
}

@Test func hibernationGitRecoveryRoundTripsHistoryIndexStashesAndWorkingBytesThroughArchive() async throws {
    let f = try GitRecoveryFixture(); defer { f.f.clean() }
    let originalIndex = try f.git(["ls-files", "--stage", "-z"]), originalStatus = try f.git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
    let originalStashes = try f.git(["reflog", "show", "--format=%H", "refs/stash"])
    let originalHistory = try f.git(["rev-list", "--all", "--reflog", "HEAD"])
    let capsule = try ProjectHibernation().create(source: f.project, destination: f.snapshots, includeGitRecovery: true, historyAcknowledged: true)
    let recovery = try #require(try ProjectGitRecovery.load(capsule: capsule))
    #expect(recovery.references.count >= 4)
    let coordinator = FolderArchiveCoordinator(catalog: f.f.catalog, remote: f.f.remote, secrets: f.f.secrets)
    let queued = try await coordinator.enqueue(source: capsule.directory, approvedRoot: capsule.directory)
    try await coordinator.run(queued.id); let verified = try await coordinator.job(queued.id)
    let card = try ProjectHibernation.memoryCard(capsule: capsule, verifiedArchive: verified)
    #expect(card.visibility == "private" && card.body.contains("older stashes/reflogs"))
    #expect(!card.body.contains(f.project.path) && !card.body.contains("OWNER_PRIVATE_CONFIGURATION"))
    let downloads = f.f.base.appendingPathComponent("Downloads"), destination = f.f.base.appendingPathComponent("Restore")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let downloaded = try await coordinator.restore(manifest: #require(verified.manifest), destination: downloads)
    let reloaded = try ProjectHibernation.loadCapsule(at: downloaded)
    let result = try ProjectGitRecovery.restore(capsule: reloaded, destination: destination, historyAcknowledged: true)
    #expect(try f.git(["ls-files", "--stage", "-z"], at: result.directory) == originalIndex)
    #expect(try f.git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: result.directory) == originalStatus)
    #expect(try f.git(["reflog", "show", "--format=%H", "refs/stash"], at: result.directory) == originalStashes)
    #expect(try f.git(["rev-list", "--all", "--reflog", "HEAD"], at: result.directory) == originalHistory)
    #expect(try f.git(["show", "stash@{1}:tracked.txt"], at: result.directory) == Data("older stash\n".utf8))
    #expect(try f.git(["show", ":staged-new.txt"], at: result.directory) == Data("index-only blob\n".utf8))
    #expect(try Data(contentsOf: result.directory.appendingPathComponent("staged-new.txt")) == Data("different working bytes\n".utf8))
    #expect(FileManager.default.isExecutableFile(atPath: result.directory.appendingPathComponent("run.sh").path))
    #expect(!FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("deleted.txt").path))
    #expect(!FileManager.default.fileExists(atPath: result.directory.appendingPathComponent(".env").path))
    #expect(try f.git(["ls-files", "--stage", "-z"]) == originalIndex)
    #expect(throws: (any Error).self) { try ProjectGitRecovery.restore(capsule: reloaded, destination: destination, historyAcknowledged: true) }
}

@Test func hibernationGitRecoveryNeverActivatesOriginalHooksConfigOrFilters() throws {
    let f = try GitRecoveryFixture(); defer { f.f.clean() }
    let marker = f.f.base.appendingPathComponent("must-not-execute")
    let hooks = f.project.appendingPathComponent(".git/custom-hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
    let hook = hooks.appendingPathComponent("reference-transaction")
    try Data(("#!/bin/sh\ntouch '" + marker.path + "'\n").utf8).write(to: hook); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    _ = try f.git(["config", "core.hooksPath", hooks.path]); _ = try f.git(["config", "core.fsmonitor", hook.path])
    _ = try f.git(["config", "filter.generated.clean", "touch '" + marker.path + "'"])
    _ = try f.git(["config", "remote.private.url", "https://credential-fixture@example.invalid/private.git"])
    let capsule = try ProjectHibernation().create(source: f.project, destination: f.snapshots, includeGitRecovery: true, historyAcknowledged: true)
    let destination = f.f.base.appendingPathComponent("Restore"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let result = try ProjectGitRecovery.restore(capsule: capsule, destination: destination, historyAcknowledged: true)
    let config = try String(contentsOf: result.directory.appendingPathComponent(".git/config"), encoding: .utf8)
    #expect(!config.contains("credential-fixture") && !config.contains(marker.path) && !config.contains("filter.generated"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(!FileManager.default.fileExists(atPath: result.directory.appendingPathComponent(".git/hooks").path))
}

@Test func hibernationGitRecoveryRequiresPrivateHistoryReviewAndRefusesTampering() throws {
    let f = try GitRecoveryFixture(); defer { f.f.clean() }
    #expect(throws: (any Error).self) { try ProjectHibernation().create(source: f.project, destination: f.snapshots, includeGitRecovery: true) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.snapshots.path).isEmpty)
    let capsule = try ProjectHibernation().create(source: f.project, destination: f.snapshots, includeGitRecovery: true, historyAcknowledged: true)
    let destination = f.f.base.appendingPathComponent("Restore"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try ProjectGitRecovery.restore(capsule: capsule, destination: destination, historyAcknowledged: false) }
    let manifestURL = capsule.directory.appendingPathComponent(ProjectGitRecovery.manifestName)
    var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]); document["headReference"] = "refs/heads/../../escape"
    try JSONSerialization.data(withJSONObject: document).write(to: manifestURL)
    #expect(throws: (any Error).self) { try ProjectGitRecovery.load(capsule: capsule) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
}

@Test func hibernationGitRecoveryRefusesExcludedTrackedContentAndExternalObjectStores() throws {
    let f = try GitRecoveryFixture(); defer { f.f.clean() }
    _ = try f.git(["add", "-f", ".env"])
    #expect(throws: (any Error).self) { try ProjectHibernation().create(source: f.project, destination: f.snapshots, includeGitRecovery: true, historyAcknowledged: true) }
    #expect(FileManager.default.fileExists(atPath: f.project.appendingPathComponent(".env").path))
    _ = try f.git(["reset", "-q", "HEAD", "--", ".env"])
    let capsule = try ProjectHibernation().create(source: f.project, destination: f.snapshots)
    try Data("/generated/nonexistent/object/store\n".utf8).write(to: f.project.appendingPathComponent(".git/objects/info/alternates"))
    #expect(throws: (any Error).self) { try ProjectGitRecovery.create(source: f.project, capsule: capsule, historyAcknowledged: true) }
}

@Test func hibernationGitRecoveryRejectsWorkingTreeChangesAfterSourceSnapshot() throws {
    let f = try GitRecoveryFixture(); defer { f.f.clean() }
    let capsule = try ProjectHibernation().create(source: f.project, destination: f.snapshots)
    try f.write("tracked.txt", "changed after snapshot\n")
    #expect(throws: (any Error).self) { try ProjectGitRecovery.create(source: f.project, capsule: capsule, historyAcknowledged: true) }
    #expect(throws: (any Error).self) { try ProjectHibernation.loadCapsule(at: capsule.directory) }
    #expect(try Data(contentsOf: f.project.appendingPathComponent("tracked.txt")) == Data("changed after snapshot\n".utf8))
}

@Test func hibernationGitRecoveryRestoresDetachedHeadAndRejectsChangedPayloads() throws {
    let f = try GitRecoveryFixture(); defer { f.f.clean() }
    let head = String(decoding: try f.git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try f.git(["checkout", "--detach", "-q", head])
    let capsule = try ProjectHibernation().create(source: f.project, destination: f.snapshots, includeGitRecovery: true, historyAcknowledged: true)
    #expect(try ProjectGitRecovery.load(capsule: capsule)?.headReference == nil)
    let destination = f.f.base.appendingPathComponent("Restore"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let result = try ProjectGitRecovery.restore(capsule: capsule, destination: destination, historyAcknowledged: true)
    let rawHead = try String(contentsOf: result.directory.appendingPathComponent(".git/HEAD"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(rawHead == head)
    let payload = capsule.directory.appendingPathComponent("git-recovery/index.data")
    let handle = try FileHandle(forWritingTo: payload); try handle.seekToEnd(); try handle.write(contentsOf: Data("tamper".utf8)); try handle.close()
    #expect(throws: (any Error).self) { try ProjectGitRecovery.load(capsule: capsule) }
}

@Test func hibernationGitRecoveryHandlesCommittedEmptyTreeWithoutAnIndexFile() throws {
    let f = try Fixture(); defer { f.clean() }
    let project = f.base.appendingPathComponent("EmptyProject"), snapshots = f.base.appendingPathComponent("Snapshots"), destination = f.base.appendingPathComponent("Restore")
    for path in [project, snapshots, destination] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
    func git(_ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", project.path] + args
        process.environment = ["PATH":"/usr/bin:/bin","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null","GIT_AUTHOR_NAME":"Fixture","GIT_AUTHOR_EMAIL":"fixture@example.invalid","GIT_COMMITTER_NAME":"Fixture","GIT_COMMITTER_EMAIL":"fixture@example.invalid"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
    }
    try git(["init", "-q", "-b", "main"]); try git(["commit", "--allow-empty", "-qm", "Empty fixture"])
    let index = project.appendingPathComponent(".git/index"); if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.removeItem(at: index) }
    let capsule = try ProjectHibernation().create(source: project, destination: snapshots, includeGitRecovery: true, historyAcknowledged: true)
    let restored = try ProjectGitRecovery.restore(capsule: capsule, destination: destination, historyAcknowledged: true)
    #expect(restored.sourceFiles == 0 && FileManager.default.fileExists(atPath: restored.directory.appendingPathComponent(".git/HEAD").path))
}
