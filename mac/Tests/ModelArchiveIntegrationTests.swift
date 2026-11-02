import Testing
import Foundation
import Darwin
@testable import CloudNestCore

@Test func modelArchivePurposeSurvivesQueueAndPortableRestore() async throws {
    let f = try Fixture(); defer { f.clean() }
    let coordinator = f.coordinator
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.base, purpose: .modelParking)
    let reopened = try Catalog(directory: f.base.appendingPathComponent("catalog"))
    #expect(try await reopened.job(job.id).purpose == .modelParking)
    try await coordinator.run(job.id)
    let completed = try await reopened.job(job.id)
    let manifest = ArchiveManifest(job: completed, driveFileID: try #require(completed.remoteID))
    #expect(try ArchiveManifest.decode(manifest.encoded()).purpose == .modelParking)
    #expect(manifest.schemaVersion == 3)
    var downgraded = try #require(JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any]); downgraded["schemaVersion"] = 1
    #expect(throws: (any Error).self) { try ArchiveManifest.decode(JSONSerialization.data(withJSONObject: downgraded)) }
    let reader = Process(); reader.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    reader.arguments = ["-f", f.source.path]; reader.standardOutput = FileHandle.nullDevice; reader.standardError = FileHandle.nullDevice
    try reader.run(); defer { if reader.isRunning { reader.terminate(); reader.waitUntilExit() } }
    usleep(150_000)
    await #expect(throws: (any Error).self) { try await coordinator.moveToRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: f.source.path))
    reader.terminate(); reader.waitUntilExit()
    try await coordinator.moveToRecovery(job.id)
    try await coordinator.putBackOriginal(job.id)
    let destination = f.base.appendingPathComponent("restored")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let restored = try await coordinator.restore(manifest: manifest, destination: destination)
    #expect(try Data(contentsOf: restored) == Data(contentsOf: f.source))
}

@Test func modelFolderPurposeSurvivesManifestAndReopenedCoordinator() async throws {
    let f = try Fixture(); defer { f.clean() }
    let source = f.base.appendingPathComponent("model-export")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("weights".utf8).write(to: source.appendingPathComponent("model.gguf"))
    let coordinator = FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets)
    let job = try await coordinator.enqueue(source: source, approvedRoot: source, purpose: .modelParking)
    let restarted = FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets)
    #expect(try await restarted.job(job.id).purpose == .modelParking)
    try await restarted.run(job.id)
    let complete = try await restarted.job(job.id)
    let manifest = try #require(complete.manifest)
    #expect(try FolderArchiveManifest.decode(manifest.encoded()).purpose == .modelParking)
    #expect(manifest.schemaVersion == 4)
    var downgraded = try #require(JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any]); downgraded["schemaVersion"] = 2
    #expect(throws: (any Error).self) { try FolderArchiveManifest.decode(JSONSerialization.data(withJSONObject: downgraded)) }
    let destination = f.base.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let restored = try await restarted.restore(manifest: manifest, destination: destination)
    #expect(try Data(contentsOf: restored.appendingPathComponent("model.gguf")) == Data("weights".utf8))
}
