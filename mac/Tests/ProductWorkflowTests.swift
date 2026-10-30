import Testing
import Foundation
@testable import CloudNestCore

@Test func transferPolicyAppliesOptInConditionsAndAcceptsUnknownOnlyWhenAllowed() throws {
    var policy = TransferPolicy()
    try policy.check(TransferEnvironment(networkKnown: false, networkAvailable: false, externalPower: nil, lowPowerMode: true))
    policy.enabled = true
    #expect(throws: TransferPolicyError.self) { try policy.check(TransferEnvironment(expensiveNetwork: true)) }
    #expect(throws: TransferPolicyError.self) { try policy.check(TransferEnvironment(constrainedNetwork: true)) }
    #expect(throws: TransferPolicyError.self) { try policy.check(TransferEnvironment(lowPowerMode: true)) }
    policy.requireExternalPower = true
    #expect(throws: TransferPolicyError.self) { try policy.check(TransferEnvironment(externalPower: nil)) }
    #expect(throws: TransferPolicyError.self) { try policy.check(TransferEnvironment(externalPower: false)) }
    try policy.check(TransferEnvironment())
    policy.uploadBytesPerSecond = -1
    #expect(throws: (any Error).self) { try policy.validate() }
}

@Test func resumablePolicyRetryAsksServerInsteadOfResendingAcceptedChunk() async throws {
    let f = try Fixture(size: ArchiveCoordinator.chunkBytes + 17); defer { f.clean() }
    var policy = TransferPolicy(); policy.enabled = true; policy.uploadBytesPerSecond = 1_000_000
    let sleeps = PolicySleepLog()
    let wrapped = try PolicyArchiveRemote(remote: f.remote, policy: policy, environment: { TransferEnvironment() }, sleep: { await sleeps.record($0) })
    let coordinator = ArchiveCoordinator(catalog: f.catalog, remote: wrapped, secrets: f.secrets)
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.base)
    await f.remote.configure(interrupt: true)
    try await coordinator.run(job.id)
    #expect(try await f.catalog.job(job.id).state == .verified)
    #expect(await f.remote.sentOffsets == [0, Int64(ArchiveCoordinator.chunkBytes)])
    #expect(await sleeps.count > 2)
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}
private actor PolicySleepLog {
    var count = 0
    func record(_ duration: Duration) { count += 1 }
}

@Test func transferPolicyPreventsNetworkCallsAndCancellationStopsPacing() async throws {
    let f = try Fixture(); defer { f.clean() }
    var policy = TransferPolicy(); policy.enabled = true; policy.requireExternalPower = true
    let remote = try PolicyArchiveRemote(remote: f.remote, policy: policy, environment: { TransferEnvironment(externalPower: false) })
    await #expect(throws: TransferPolicyError.self) { try await remote.allocateID() }
    #expect(await f.remote.objects.isEmpty)
    policy.requireExternalPower = false; policy.uploadBytesPerSecond = 65_536
    let paced = try PolicyArchiveRemote(remote: f.remote, policy: policy, environment: { TransferEnvironment() })
    let session = await f.remote.begin(id: "cancel-policy", name: "payload", size: 1024 * 1024, jobID: UUID())
    let task = Task { try await paced.send(session: session, data: Data(repeating: 1, count: 1024 * 1024), offset: 0, total: 1024 * 1024) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await f.remote.sentOffsets.isEmpty)
}

@Test func activityHistoryPersistsDeduplicatesAndPagesActualEvents() async throws {
    let f = try Fixture(); defer { f.clean() }
    let folder = f.base.appendingPathComponent("activity")
    let first = try ActivityLedger(directory: folder)
    let jobID = UUID()
    try await first.append(StorageActivity(kind: .archiveVerified, title: "test", jobID: jobID), deduplicationKey: jobID.uuidString)
    try await first.append(StorageActivity(kind: .archiveVerified, title: "duplicate", jobID: jobID), deduplicationKey: jobID.uuidString)
    for n in 0..<120 { try await first.append(StorageActivity(kind: .restored, title: "Restore \(n)")) }
    let reopened = try ActivityLedger(directory: folder)
    #expect(try await reopened.count() == 121)
    #expect(try await reopened.events(limit: 50).count == 50)
    #expect(try await reopened.events(limit: 50, offset: 100).count == 21)
    #expect(try await reopened.events(limit: 1).first?.title == "Restore 119")
}

@Test func recommendationExclusionsAndScheduleRemainConservative() throws {
    let f = try Fixture(); defer { f.clean() }
    let root = f.base.appendingPathComponent("recommendations")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("keep"), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("video.mov"))
    try Data(repeating: 1, count: 16384).write(to: root.appendingPathComponent("notes.txt"))
    try Data(repeating: 1, count: 32768).write(to: root.appendingPathComponent("keep/larger.mov"))
    let report = try FileScanner().scan(root: root, minimumBytes: 0)
    var rules = RecommendationRules(); rules.excludedExtensions = [".TXT"]; rules.excludedPathComponents = ["keep"]
    let filtered = rules.filter(report)
    #expect(filtered.candidates.count == 1)
    #expect(filtered.excluded == report.excluded + 2)
    #expect(SpaceRescue.rank(filtered).first?.candidate.url.lastPathComponent == "video.mov")
    #expect(SpaceRescue.byFolder(report, root: root).reduce(0) { $0 + $1.files } == 3)
    var schedule = RecommendationSchedule(); let now = Date()
    #expect(!schedule.isDue(now: now))
    schedule.enabled = true; schedule.lastCompleted = now
    #expect(!schedule.isDue(now: now.addingTimeInterval(86_400)))
    #expect(schedule.isDue(now: now.addingTimeInterval(8 * 86_400)))
}

@Test func recommendationMergeAvoidsOverlappingRootsAndHardLinksAcrossRoots() throws {
    let f = try Fixture(); defer { f.clean() }
    let first = f.base.appendingPathComponent("first"), second = f.base.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: first.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
    let file = first.appendingPathComponent("nested/data.bin")
    try Data(repeating: 1, count: 4096).write(to: file)
    try FileManager.default.linkItem(at: file, to: second.appendingPathComponent("alias.bin"))
    #expect(SpaceRescue.nonoverlappingRoots([first.appendingPathComponent("nested"), first, second, first]).count == 2)
    let merged = SpaceRescue.merge([try FileScanner().scan(root: first, minimumBytes: 0), try FileScanner().scan(root: second, minimumBytes: 0)])
    #expect(merged.candidates.count == 1)
    #expect(merged.allocatedBytes == (try FileScanner().scan(root: first, minimumBytes: 0)).allocatedBytes)
}
