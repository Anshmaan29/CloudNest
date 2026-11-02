import Testing
import Foundation
@testable import CloudNestCore

@Test @MainActor func foregroundLeaseRejectsReenteredSectionAndStaleCompletion() throws {
    let gate = ForegroundOperationGate()
    let first = try #require(gate.acquire())
    #expect(gate.acquire() == nil) // A recreated view cannot rely on stale busy props.
    #expect(!gate.release(UUID()))
    #expect(gate.acquire() == nil)
    #expect(gate.release(first))
    let second = try #require(gate.acquire())
    #expect(second != first)
    #expect(!gate.release(first)) // Old task's completion cannot unlock new work.
    #expect(gate.acquire() == nil)
    #expect(gate.release(second))
}

@Test func projectCardRetryIdentitySurvivesRestartAndChangesAfterConfirmedSave() async throws {
    let f = try Fixture(); defer { f.clean() }
    let archive = UUID(), digest = String(repeating: "a", count: 64)
    let first = try await f.catalog.beginProjectCardSave(archiveID: archive, digest: digest)
    let reopened = try Catalog(directory: f.base.appendingPathComponent("catalog"))
    #expect(try await reopened.beginProjectCardSave(archiveID: archive, digest: digest) == first)
    try await reopened.confirmProjectCardSave(archiveID: archive, operationID: first)
    let recreated = try await reopened.beginProjectCardSave(archiveID: archive, digest: digest)
    #expect(recreated != first) // Same card saved after deletion is a new logical write.
    let edited = try await reopened.beginProjectCardSave(archiveID: archive, digest: String(repeating: "b", count: 64))
    #expect(edited != recreated)
    try await reopened.confirmProjectCardSave(archiveID: archive, operationID: recreated)
    #expect(try await reopened.beginProjectCardSave(archiveID: archive, digest: String(repeating: "b", count: 64)) == edited)
}

@Test func lostAcknowledgmentRetiresOnlyTheConfirmedCardDigest() async throws {
    let f = try Fixture(); defer { f.clean() }
    let archive = UUID(), digest = String(repeating: "a", count: 64)
    let uncertain = try await f.catalog.beginProjectCardSave(archiveID: archive, digest: digest)
    try await f.catalog.retireConfirmedProjectCardSave(archiveID: archive, digest: String(repeating: "b", count: 64))
    #expect(try await f.catalog.beginProjectCardSave(archiveID: archive, digest: digest) == uncertain)
    try await f.catalog.retireConfirmedProjectCardSave(archiveID: archive, digest: digest)
    #expect(try await f.catalog.beginProjectCardSave(archiveID: archive, digest: digest) != uncertain)
}
