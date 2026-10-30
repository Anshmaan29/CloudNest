import Testing
import Foundation
import Darwin
@testable import CloudNestCore

private struct CapsuleFixture {
    let base: URL
    let source: URL
    let destination: URL
    init() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        base = repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/capsule-tests-" + UUID().uuidString)
        source = base.appendingPathComponent("Project"); destination = base.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("print(\"hello\")\n".utf8).write(to: source.appendingPathComponent("Sources/main.swift"))
        try Data("{\"name\":\"capsule-fixture\"}".utf8).write(to: source.appendingPathComponent("package.json"))
        try Self.git(["init", "-q"], source)
        try Self.git(["add", "Sources/main.swift", "package.json"], source)
        try Self.git(["-c", "user.name=CloudNest Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "fixture"], source)
    }
    static func git(_ arguments: [String], _ source: URL) throws {
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        command.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", source.path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_TERMINAL_PROMPT"] = "0"
        command.environment = environment; command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
        try command.run(); command.waitUntilExit(); guard command.terminationStatus == 0 else { throw NestError.invalidResponse }
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
}
private final class CapsuleOnce: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func perform(_ action: () -> Void) { lock.lock(); defer { lock.unlock() }; guard !done else { return }; done = true; action() }
}

@Test func projectCapsuleCopiesWorkingTreeAndRecordsExclusionsWithoutChangingGit() throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    try Data("print(\"edited\")\n".utf8).write(to: f.source.appendingPathComponent("Sources/main.swift"))
    try Data("private environment value".utf8).write(to: f.source.appendingPathComponent(".env"))
    try Data("API_KEY=${YOUR_API_KEY}\nPORT=3000\n".utf8).write(to: f.source.appendingPathComponent(".env.example"))
    try FileManager.default.createDirectory(at: f.source.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
    try Data("regenerable".utf8).write(to: f.source.appendingPathComponent("node_modules/pkg/index.js"))
    try Data("#!/bin/sh\necho recovered\n".utf8).write(to: f.source.appendingPathComponent("run.sh"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.source.appendingPathComponent("run.sh").path)
    try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("linked"), withDestinationURL: f.base)
    let result = try ProjectTimeCapsule().create(source: f.source, destination: f.destination, description: "Disposable snapshot")
    #expect(result.manifest.git.includesWorkingTreeChanges)
    #expect(!result.manifest.git.trackedChanges.isEmpty)
    #expect(result.manifest.files.first { $0.path == "Sources/main.swift" }?.differsFromGitIndex == true)
    #expect(result.manifest.files.first { $0.path == "package.json" }?.differsFromGitIndex == false)
    #expect(result.manifest.git.untrackedFiles.contains("run.sh"))
    #expect(result.manifest.git.commit.count == 40 || result.manifest.git.commit.count == 64)
    #expect(!result.manifest.permitsOriginalCleanup)
    #expect(result.manifest.dependencyManifests == ["package.json"])
    #expect(result.manifest.excluded.contains { $0.path == ".git" })
    #expect(result.manifest.excluded.contains { $0.path == ".env" })
    #expect(result.manifest.excluded.contains { $0.path == "node_modules" })
    #expect(result.manifest.excluded.contains { $0.path == "linked" })
    #expect(try Data(contentsOf: result.directory.appendingPathComponent("source/Sources/main.swift")) == Data("print(\"edited\")\n".utf8))
    #expect(FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("source/.env.example").path))
    #expect(!FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("source/.env").path))
    var executable = stat(); #expect(lstat(result.directory.appendingPathComponent("source/run.sh").path, &executable) == 0)
    #expect(executable.st_mode & 0o100 != 0)
    #expect(FileManager.default.fileExists(atPath: result.manifestURL.path))
    #expect(FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("RESTORE.md").path))
    // Snapshot output is outside the repository and can use the ordinary safe folder engine.
    try FileSafety().validate(result.directory, root: result.directory)
    #expect(try Data(contentsOf: f.source.appendingPathComponent(".env")) == Data("private environment value".utf8))
    #expect(FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git").path))
}

@Test func projectCapsuleExcludesCredentialContentAndUnsafeTemplates() throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    let credential = "gh" + "p_" + String(repeating: "A", count: 36)
    try Data(("export let value = \"" + credential + "\";\n").utf8).write(to: f.source.appendingPathComponent("unsafe.ts"))
    try Data("DB_PASSWORD=actual-private-value\n".utf8).write(to: f.source.appendingPathComponent(".env.template"))
    try Data("key bytes".utf8).write(to: f.source.appendingPathComponent("account.pem"))
    let result = try ProjectTimeCapsule().create(source: f.source, destination: f.destination)
    #expect(result.manifest.excluded.contains { $0.path == "unsafe.ts" })
    #expect(result.manifest.excluded.contains { $0.path == ".env.template" })
    #expect(result.manifest.excluded.contains { $0.path == "account.pem" })
    #expect(!FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("source/unsafe.ts").path))
    #expect(!FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("source/.env.template").path))
    #expect(!String(decoding: try Data(contentsOf: result.manifestURL), as: UTF8.self).contains(credential))
}

@Test func projectCapsuleRefusesProtectedSourcesDestinationsAndOversizedTrees() throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    #expect(throws: (any Error).self) { try ProjectTimeCapsule(protectedRoots: [f.source]).create(source: f.source, destination: f.destination) }
    #expect(throws: (any Error).self) { try ProjectTimeCapsule().create(source: f.source, destination: f.source) }
    let link = f.base.appendingPathComponent("destination-link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.destination)
    #expect(throws: (any Error).self) { try ProjectTimeCapsule().create(source: f.source, destination: link) }
    var limits = ProjectCapsuleLimits(); limits.maximumBytes = 1
    #expect(throws: (any Error).self) { try ProjectTimeCapsule(limits: limits).create(source: f.source, destination: f.destination) }
    #expect(!((try FileManager.default.contentsOfDirectory(atPath: f.destination.path)).contains { $0.hasPrefix("ProjectCapsule-") }))
}

@Test func projectCapsuleAbortsOnSourceChangesAndDoesNotPublishPartialSnapshot() throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    let once = CapsuleOnce()
    #expect(throws: (any Error).self) {
        try ProjectTimeCapsule().create(source: f.source, destination: f.destination, onProgress: { _, _ in
            once.perform { try? Data("source changed during snapshot".utf8).write(to: f.source.appendingPathComponent("Sources/main.swift")) }
        })
    }
    #expect(try Data(contentsOf: f.source.appendingPathComponent("Sources/main.swift")) == Data("source changed during snapshot".utf8))
    #expect(!((try FileManager.default.contentsOfDirectory(atPath: f.destination.path)).contains { $0.hasPrefix("ProjectCapsule-") }))
}

@Test func projectCapsuleDoesNotExecuteFsmonitorAndRetainsUnexpectedStagingData() throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    let marker = f.base.appendingPathComponent("unexpected-hook-run")
    let hook = f.source.appendingPathComponent(".git/fsmonitor-test")
    try Data(("#!/bin/sh\ntouch '" + marker.path + "'\n").utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try CapsuleFixture.git(["config", "core.fsmonitor", hook.path], f.source)
    let once = CapsuleOnce()
    #expect(throws: (any Error).self) {
        try ProjectTimeCapsule().create(source: f.source, destination: f.destination, onProgress: { _, _ in
            once.perform {
                let stages = try? FileManager.default.contentsOfDirectory(at: f.destination.appendingPathComponent(".cloudnest-recovery"), includingPropertiesForKeys: nil)
                if let stage = stages?.first { try? Data("unexpected retained bytes".utf8).write(to: stage.appendingPathComponent("source/injected.txt")) }
            }
        })
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    let stages = try FileManager.default.contentsOfDirectory(at: f.destination.appendingPathComponent(".cloudnest-recovery"), includingPropertiesForKeys: nil)
    #expect(stages.count == 1)
    let stage = try #require(stages.first)
    #expect(try Data(contentsOf: stage.appendingPathComponent("source/injected.txt")) == Data("unexpected retained bytes".utf8))
}

@Test func projectCapsuleCancellationLeavesOriginalRepositoryUntouched() async throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    let original = try Data(contentsOf: f.source.appendingPathComponent("Sources/main.swift"))
    let task = Task.detached { withUnsafeCurrentTask { $0?.cancel() }; return try ProjectTimeCapsule().create(source: f.source, destination: f.destination) }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: f.source.appendingPathComponent("Sources/main.swift")) == original)
}

@Test func projectCapsuleDoesNotInvokeRepositoryCleanFilters() throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    let marker = f.base.appendingPathComponent("unexpected-clean-filter")
    let hook = f.source.appendingPathComponent(".git/clean-filter-test")
    try Data(("#!/bin/sh\ntouch '" + marker.path + "'\ncat\n").utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try Data("*.swift filter=cloudnest-test\n".utf8).write(to: f.source.appendingPathComponent(".gitattributes"))
    try CapsuleFixture.git(["config", "filter.cloudnest-test.clean", hook.path], f.source)
    try Data("print(\"changed working tree\")\n".utf8).write(to: f.source.appendingPathComponent("Sources/main.swift"))
    let result = try ProjectTimeCapsule().create(source: f.source, destination: f.destination)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(result.manifest.files.first { $0.path == "Sources/main.swift" }?.differsFromGitIndex == true)
    #expect(!result.manifest.git.trackedChanges.isEmpty)
}

@Test func projectCapsuleRetainsChangedStagedBytesAndNeverPublishesThem() throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    let once = CapsuleOnce()
    #expect(throws: (any Error).self) {
        try ProjectTimeCapsule().create(source: f.source, destination: f.destination, onProgress: { _, _ in
            once.perform {
                let stages = try? FileManager.default.contentsOfDirectory(at: f.destination.appendingPathComponent(".cloudnest-recovery"), includingPropertiesForKeys: nil)
                if let stage = stages?.first { try? Data("changed staging bytes to preserve".utf8).write(to: stage.appendingPathComponent("source/Sources/main.swift")) }
            }
        })
    }
    let stages = try FileManager.default.contentsOfDirectory(at: f.destination.appendingPathComponent(".cloudnest-recovery"), includingPropertiesForKeys: nil)
    let stage = try #require(stages.first)
    #expect(try Data(contentsOf: stage.appendingPathComponent("source/Sources/main.swift")) == Data("changed staging bytes to preserve".utf8))
    #expect(try Data(contentsOf: f.source.appendingPathComponent("Sources/main.swift")) == Data("print(\"hello\")\n".utf8))
    #expect(!((try FileManager.default.contentsOfDirectory(atPath: f.destination.path)).contains { $0.hasPrefix("ProjectCapsule-") }))
}

@Test func projectCapsuleUsesOrdinaryVerifiedFolderArchiveAndRestore() async throws {
    let f = try CapsuleFixture(); defer { f.clean() }
    let snapshot = try ProjectTimeCapsule().create(source: f.source, destination: f.destination)
    let db = try Catalog(directory: f.base.appendingPathComponent("catalog")), remote = TestRemote(), secrets = TestSecrets()
    let folder = FolderArchiveCoordinator(catalog: db, remote: remote, secrets: secrets)
    let job = try await folder.enqueue(source: snapshot.directory, approvedRoot: snapshot.directory)
    try await folder.run(job.id)
    let completed = try await folder.job(job.id), manifest = try #require(completed.manifest)
    let destination = f.base.appendingPathComponent("restored")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let restored = try await folder.restore(manifest: manifest, destination: destination)
    #expect(try Data(contentsOf: restored.appendingPathComponent("source/Sources/main.swift")) == Data(contentsOf: snapshot.directory.appendingPathComponent("source/Sources/main.swift")))
    #expect(try Data(contentsOf: restored.appendingPathComponent("CLOUDNEST_PROJECT.json")) == Data(contentsOf: snapshot.manifestURL))
    #expect(FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git").path))
}
