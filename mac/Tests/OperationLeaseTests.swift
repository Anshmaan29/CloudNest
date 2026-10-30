import Testing
import Foundation
import Darwin
@testable import CloudNestCore

@Test func independentlyOpenedLeasesExcludeEachOtherAndRelease() throws {
    let f = try Fixture(); defer { f.clean() }
    let id = UUID()
    var lease: OperationLease? = try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: id)
    try withExtendedLifetime(lease) {
        #expect(throws: NestError.self) { try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: id) }
        let independent = try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: UUID())
        withExtendedLifetime(independent) {}
    }
    lease = nil
    let reopened = try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: id)
    withExtendedLifetime(reopened) {}
}

@Test func leaseRejectsLinksAndPublicPermissionsWithoutChangingPayload() throws {
    let f = try Fixture(); defer { f.clean() }
    let linkID = UUID()
    let link = f.base.appendingPathComponent("catalog").appendingPathComponent(".operation-" + linkID.uuidString + ".lock")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
    #expect(throws: (any Error).self) { try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: linkID) }
    #expect(try Data(contentsOf: f.source) == Data(repeating: 0xA7, count: 1024))
    let publicID = UUID()
    let publicFile = f.base.appendingPathComponent("catalog").appendingPathComponent(".operation-" + publicID.uuidString + ".lock")
    try Data().write(to: publicFile)
    #expect(chmod(publicFile.path, 0o644) == 0)
    #expect(throws: (any Error).self) { try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: publicID) }
}

@Test func competingCoordinatorsCannotMutateLeasedJobs() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    let lease = try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: job.id)
    defer { withExtendedLifetime(lease) {} }
    let independentlyOpened = try Catalog(directory: f.base.appendingPathComponent("catalog"))
    let competitor = ArchiveCoordinator(catalog: independentlyOpened, remote: f.remote, secrets: f.secrets)
    await #expect(throws: NestError.self) { try await competitor.run(job.id) }
    await #expect(throws: NestError.self) { try await competitor.moveToRecovery(job.id) }
    await #expect(throws: NestError.self) { try await competitor.permanentlyRemoveRecovery(job.id) }
    await #expect(throws: NestError.self) { try await competitor.putBackOriginal(job.id) }
    let unchanged = try await independentlyOpened.job(job.id)
    #expect(unchanged.state == .queued && unchanged.offset == 0 && unchanged.remoteID == nil && unchanged.recovery == nil && unchanged.lastError == nil)
    #expect(await f.remote.sentOffsets.isEmpty)
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func reconciliationSkipsActiveLeasesAndRechecksAfterRelease() async throws {
    let f = try Fixture(); defer { f.clean() }
    var job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    job.recovery = LocalRecovery(stage: .moving); try await f.catalog.save(job)
    var lease: OperationLease? = try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: job.id)
    try await f.coordinator.reconcileRecovery()
    #expect(try await f.catalog.job(job.id).recovery?.stage == .moving)
    withExtendedLifetime(lease) {}
    lease = nil
    try await f.coordinator.reconcileRecovery()
    #expect(try await f.catalog.job(job.id).recovery == nil)
}

@Test func leaseExcludesAnotherProcessAndReleasesAfterProcessDeath() async throws {
    let f = try Fixture(); defer { f.clean() }
    let id = UUID(), ready = f.base.appendingPathComponent("lease-ready")
    let lock = f.base.appendingPathComponent("catalog").appendingPathComponent(".operation-" + id.uuidString + ".lock")
    // Direct POSIX spawning/reaping avoids Foundation Process.waitUntilExit's
    // run-loop notification race after SIGKILL on a Swift concurrency executor.
    let arguments = ["/usr/bin/python3", "-c", "import fcntl,os,signal,sys; fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600); fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); open(sys.argv[2],'w').close(); signal.pause()", lock.path, ready.path]
    var argv = arguments.map { strdup($0) } + [nil]
    var environment = [strdup("PATH=/usr/bin:/bin"), nil]
    defer { for value in argv { free(value) }; for value in environment { free(value) } }
    var attributes: posix_spawnattr_t?
    try #require(posix_spawnattr_init(&attributes) == 0)
    defer { posix_spawnattr_destroy(&attributes) }
    // A concurrently running test may have file descriptors open. The lease
    // child must not inherit those descriptors and masquerade as an active user.
    try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
    var pid: pid_t = 0
    let launched = argv.withUnsafeMutableBufferPointer { arguments in
        environment.withUnsafeMutableBufferPointer { env in posix_spawn(&pid, "/usr/bin/python3", nil, &attributes, arguments.baseAddress!, env.baseAddress!) }
    }
    try #require(launched == 0)
    var reaped = false, status: Int32 = 0
    defer { if !reaped { _ = kill(pid, SIGKILL); _ = waitpid(pid, &status, WNOHANG) } }
    let readyDeadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: ready.path) && Date() < readyDeadline {
        if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: ready.path))
    #expect(throws: NestError.self) { try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: id) }
    #expect(kill(pid, SIGKILL) == 0)
    let exitDeadline = Date().addingTimeInterval(10)
    while !reaped && Date() < exitDeadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) { reaped = true; break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(reaped)
    let recovered = try OperationLease.acquire(catalogDirectory: f.base.appendingPathComponent("catalog"), jobID: id)
    withExtendedLifetime(recovered) {}
}
