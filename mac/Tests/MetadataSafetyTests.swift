import Testing
import Foundation
import Darwin
@testable import CloudNestCore

private func addTestMetadata(_ url: URL) throws {
    let metadata = Data("metadata that is not in the data-fork manifest".utf8)
    let result = metadata.withUnsafeBytes { bytes in
        setxattr(url.path, "com.cloudnest.test", bytes.baseAddress, bytes.count, 0, 0)
    }
    guard result == 0 else { throw NestError.unsafePath("test filesystem does not support extended attributes") }
}

@Test func fileWithExtendedAttributesCanArchiveButNeverMovesIntoCleanup() async throws {
    let f = try Fixture(); defer { f.clean() }
    try addTestMetadata(f.source)
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    #expect(try await f.catalog.job(job.id).state == .verified)
    await #expect(throws: (any Error).self) { try await f.coordinator.moveToRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: f.source.path))
    #expect(try await f.catalog.job(job.id).recovery == nil)
    #expect(getxattr(f.source.path, "com.cloudnest.test", nil, 0, 0, 0) > 0)
}

@Test func metadataAddedAfterStagingBlocksPermanentRemovalAndSurvivesPutBack() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    try await f.coordinator.moveToRecovery(job.id)
    let retained = RecoveryFiles.payload(job)
    try addTestMetadata(retained)
    await #expect(throws: (any Error).self) { try await f.coordinator.permanentlyRemoveRecovery(job.id) }
    #expect(FileManager.default.fileExists(atPath: retained.path))
    #expect(try await f.catalog.job(job.id).recovery?.stage != .removed)
    #expect(getxattr(retained.path, "com.cloudnest.test", nil, 0, 0, 0) > 0)
    try await f.coordinator.putBackOriginal(job.id)
    #expect(getxattr(f.source.path, "com.cloudnest.test", nil, 0, 0, 0) > 0)
    #expect(try Data(contentsOf: f.source) == Data(repeating: 0xA7, count: 1024))
}

@Test func uncertainMetadataReadFailsClosed() {
    #expect(throws: (any Error).self) { try FileSafety.requireArchivedMetadata(descriptor: -1, provenance: nil) }
}

@Test func cleanupRequiresExactRecordedProvenanceInsteadOfAnUnrecordedException() throws {
    let f = try Fixture(); defer { f.clean() }
    let file = try FileSafety().openSource(f.source, root: f.base); defer { try? file.close() }
    let recorded = try FileSafety.provenance(descriptor: file.fileDescriptor)
    try FileSafety.requireArchivedMetadata(descriptor: file.fileDescriptor, provenance: recorded)
    let incorrect: Data? = recorded == nil ? Data([0x01]) : nil
    #expect(throws: (any Error).self) { try FileSafety.requireArchivedMetadata(descriptor: file.fileDescriptor, provenance: incorrect) }
    try addTestMetadata(f.source)
    #expect(throws: (any Error).self) { try FileSafety.requireArchivedMetadata(descriptor: file.fileDescriptor, provenance: recorded) }
}

@Test func portableManifestPreservesProvenanceAndLegacyEncodingOmitsAbsentField() throws {
    let f = try Fixture(); defer { f.clean() }
    let actual = try FileSafety().snapshot(f.source, root: f.base)
    let marker = Data([1, 2, 3, 4])
    let withMarker = Snapshot(identity: actual.identity, sha256: actual.sha256, provenance: marker)
    let job = ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: withMarker)
    let encoded = try ArchiveManifest(job: job, driveFileID: "recorded-marker").encoded()
    #expect(try ArchiveManifest.decode(encoded).provenance == marker)
    #expect(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(withMarker)).provenance == marker)
    let legacy = Snapshot(identity: actual.identity, sha256: actual.sha256)
    let legacyJob = ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: legacy)
    let legacyData = try ArchiveManifest(job: legacyJob, driveFileID: "legacy-file").encoded()
    #expect((try JSONSerialization.jsonObject(with: legacyData) as? [String: Any])?["provenance"] == nil)
    #expect(try ArchiveManifest.decode(legacyData).provenance == nil)
    #expect((try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])?["provenance"] == nil)
}

@Test func provenanceManifestRejectsUnboundedMarkerAndCloudManifestContainsRecordedEvidence() async throws {
    let f = try Fixture(); defer { f.clean() }
    let actual = try FileSafety().snapshot(f.source, root: f.base)
    let oversized = Snapshot(identity: actual.identity, sha256: actual.sha256, provenance: Data(repeating: 1, count: 4097))
    let badJob = ArchiveJob(source: f.source, approvedRoot: f.base, snapshot: oversized)
    #expect(throws: (any Error).self) { try ArchiveManifest(job: badJob, driveFileID: "too-large").encoded() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    let complete = try await f.catalog.job(job.id)
    let manifestID = try #require(complete.manifestID)
    let remoteData = try #require(await f.remote.objects[manifestID])
    #expect(try ArchiveManifest.decode(remoteData).provenance == job.snapshot.provenance)
}
