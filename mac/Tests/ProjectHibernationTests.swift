import Testing
import Foundation
import Darwin
@testable import CloudNestCore

private struct HibernationFixture {
    let f: Fixture
    let project: URL
    let destination: URL
    init() throws {
        f = try Fixture(); project = f.base.appendingPathComponent("ExampleProject"); destination = f.base.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("print(\"fixture\")\n".utf8).write(to: project.appendingPathComponent("Sources/main.swift"))
        try Data("// swift-tools-version: 6.0\n".utf8).write(to: project.appendingPathComponent("Package.swift"))
        try Self.git(["init", "-q"], at: project)
        try Self.git(["add", "."], at: project)
        try Self.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], at: project)
        try Data("OWNER_PRIVATE_CONFIGURATION=private-fixture\n".utf8).write(to: project.appendingPathComponent(".env"))
    }
    static func git(_ args: [String], at directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", directory.path] + args
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw NestError.invalidResponse }
    }
    var coordinator: FolderArchiveCoordinator { FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets) }
}

@Test func projectHibernationArchivesRestoresAndBuildsPrivateEditableCard() async throws {
    let fixture = try HibernationFixture(); defer { fixture.f.clean() }
    let capsule = try ProjectHibernation().create(source: fixture.project, destination: fixture.destination)
    let recovered = try ProjectHibernation.loadCapsule(at: capsule.directory)
    #expect(recovered.manifest.id == capsule.manifest.id)
    let coordinator = fixture.coordinator
    let queued = try await coordinator.enqueue(source: capsule.directory, approvedRoot: capsule.directory)
    #expect(throws: (any Error).self) { try ProjectHibernation.memoryCard(capsule: capsule, verifiedArchive: queued) }
    try await coordinator.run(queued.id)
    let verified = try await coordinator.job(queued.id)
    var card = try ProjectHibernation.memoryCard(capsule: capsule, verifiedArchive: verified, decisions: "Use native UI", nextAction: "Review sources before building")
    #expect(card.visibility == "private")
    #expect(card.project.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil)
    #expect(card.body.utf8.count <= 20_000)
    #expect(card.body.contains(queued.id.uuidString))
    #expect(card.body.contains("Swift") && card.body.contains("Use native UI"))
    #expect(!card.body.contains(fixture.project.path) && !card.body.contains("OWNER_PRIVATE_CONFIGURATION"))
    #expect(!card.body.contains("print(\"fixture\")"))
    #expect(card.body.contains("Original repository retained"))
    card.body += "\nOwner correction."; #expect(card.body.hasSuffix("Owner correction."))
    let restore = fixture.f.base.appendingPathComponent("Restore")
    try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: false)
    let restored = try await coordinator.restore(manifest: #require(verified.manifest), destination: restore)
    #expect(try Data(contentsOf: restored.appendingPathComponent("source/Sources/main.swift")) == Data(contentsOf: fixture.project.appendingPathComponent("Sources/main.swift")))
    #expect(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".git/HEAD").path))
    #expect(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".env").path))
    #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("source/.env").path))
}

@Test func projectHibernationRejectsChangedCapsuleAndWrongArchiveBinding() async throws {
    let fixture = try HibernationFixture(); defer { fixture.f.clean() }
    let capsule = try ProjectHibernation().create(source: fixture.project, destination: fixture.destination)
    let coordinator = fixture.coordinator
    let job = try await coordinator.enqueue(source: capsule.directory, approvedRoot: capsule.directory)
    try await coordinator.run(job.id)
    let verified = try await coordinator.job(job.id)
    let wrong = ProjectCapsuleResult(directory: fixture.destination, manifest: capsule.manifest)
    #expect(throws: (any Error).self) { try ProjectHibernation.memoryCard(capsule: wrong, verifiedArchive: verified) }
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: capsule.manifestURL)) as? [String: Any])
    var entries = try #require(object["files"] as? [[String: Any]])
    entries[0]["path"] = "../escape"; object["files"] = entries
    try JSONSerialization.data(withJSONObject: object).write(to: capsule.manifestURL)
    #expect(throws: (any Error).self) { try ProjectHibernation.loadCapsule(at: capsule.directory) }
    #expect(throws: (any Error).self) { try ProjectHibernation.memoryCard(capsule: capsule, verifiedArchive: verified) }
}

@Test func projectHibernationRefusesOpenProjectsAndProtectedDestinations() throws {
    let fixture = try HibernationFixture(); defer { fixture.f.clean() }
    let reader = Process(); reader.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    reader.arguments = ["-f", fixture.project.appendingPathComponent("Sources/main.swift").path]
    reader.standardOutput = FileHandle.nullDevice; reader.standardError = FileHandle.nullDevice
    try reader.run(); defer { if reader.isRunning { reader.terminate(); reader.waitUntilExit() } }
    usleep(150_000)
    #expect(throws: (any Error).self) { try ProjectHibernation().create(source: fixture.project, destination: fixture.destination) }
    reader.terminate(); reader.waitUntilExit()
    #expect(throws: (any Error).self) { try ProjectHibernation(protectedRoots: [fixture.destination]).create(source: fixture.project, destination: fixture.destination) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}
