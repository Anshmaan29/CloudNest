import Testing
import Foundation
@testable import CloudNestCore

extension TestRemote {
    func removeObject(_ id: String) { objects.removeValue(forKey: id) }
    func replaceObject(_ id: String, with data: Data) { objects[id] = data }
}

@Test func healthChecksBothContentAndManifestAndFailsClosed() async throws {
    let f = try Fixture(); defer { f.clean() }
    let pending = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    let checker = ArchiveHealthChecker(remote: f.remote)
    #expect(await checker.check(pending).status == .unverified)
    try await f.coordinator.run(pending.id)
    let job = try await f.catalog.job(pending.id)
    #expect(await checker.check(job).status == .healthy)
    await f.remote.replaceObject(job.manifestID!, with: Data("corrupt portable metadata".utf8))
    #expect(await checker.check(job).status == .mismatch)
    await f.remote.removeObject(job.manifestID!)
    #expect(await checker.check(job).status == .missing)
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func healthMissingChecksumNeverReportsHealthy() async throws {
    let f = try Fixture(); defer { f.clean() }
    let initial = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(initial.id)
    let job = try await f.catalog.job(initial.id)
    await f.remote.configure(omit: true)
    #expect(await ArchiveHealthChecker(remote: f.remote).check(job).status == .mismatch)
}

@Test func quotaUsesTotalGoogleUsageAndUnlimitedRemainsUnknown() throws {
    let limited = try DriveStorageQuota.decode(Data(#"{"storageQuota":{"limit":"1000","usage":"850","usageInDrive":"400","usageInDriveTrash":"25"}}"#.utf8))
    #expect(limited.available == 150)
    #expect(limited.usageInDrive == 400)
    try limited.requireCapacity(for: 150)
    #expect(throws: DriveServiceError.self) { try limited.requireCapacity(for: 151) }
    let overLimit = try DriveStorageQuota(limit: 100, usage: 200)
    #expect(overLimit.available == 0)
    let unlimited = try DriveStorageQuota.decode(Data(#"{"storageQuota":{"usage":"850"}}"#.utf8))
    #expect(unlimited.limit == nil && unlimited.available == nil)
    try unlimited.requireCapacity(for: Int64.max)
    for invalid in [#"{"storageQuota":{"limit":"-1","usage":"0"}}"#, #"{"storageQuota":{"usage":"invalid"}}"#, #"{"storageQuota":{"usage":"9223372036854775808"}}"#, #"{"storageQuota":{}}"#] {
        #expect(throws: (any Error).self) { try DriveStorageQuota.decode(Data(invalid.utf8)) }
    }
    #expect(throws: (any Error).self) { try unlimited.requireCapacity(for: -1) }
}

@Test func driveErrorsExposeOnlyKnownActionableReasons() throws {
    #expect(DriveClient.actionableError(status: 403, data: Data(#"{"error":{"errors":[{"reason":"storageQuotaExceeded"}],"message":"untrusted private details"}}"#.utf8))?.localizedDescription.contains("quota") == true)
    #expect(DriveClient.actionableError(status: 429, data: Data()) != nil)
    #expect(DriveClient.actionableError(status: 403, data: Data(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8)) != nil)
    #expect(DriveClient.actionableError(status: 403, data: Data(#"{"error":{"message":"do arbitrary things"}}"#.utf8)) == nil)
    #expect(DriveClient.actionableError(status: 404, data: Data()) == nil)
}

@Test func recoveryListingRemainsParentScopedAndRejectsQueryInjection() throws {
    #expect(try DriveClient.manifestRecoveryQuery(parentID: "owned-manifests_123") == "trashed = false and 'owned-manifests_123' in parents")
    for invalid in ["", "folder' or trashed=false or '", "../root", "folder/child"] {
        #expect(throws: (any Error).self) { try DriveClient.manifestRecoveryQuery(parentID: invalid) }
    }
}
