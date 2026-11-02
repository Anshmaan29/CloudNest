import Testing
import Foundation
import Darwin
@testable import CloudNestCore

private struct SweepFixture {
    let base: URL
    let project: URL
    let root: URL
    init() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        base = repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("sweep-tests-" + UUID().uuidString + ".noindex")
        project = base.appendingPathComponent("project"); root = project.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: project.appendingPathComponent("package-lock.json"))
    }
    func write(_ name: String, _ value: String = "generated fixture") throws {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: path)
    }
    func preview(_ driver: SmartSweep = SmartSweep()) async throws -> SmartSweepPreview { try await driver.preview(root: root, kind: .nodeModules, dependencyEditsAcknowledged: true) }
    func staged(_ driver: SmartSweep = SmartSweep()) async throws -> SmartSweepRecovery { try await driver.stage(approved: preview(driver)) }
    func clean() { try? FileManager.default.removeItem(at: base) }
}

@Test func sweepDryRunStagesAndPutsBackExactGeneratedContentOffline() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("package/file.txt", "generated payload")
    let preview = try await f.preview()
    #expect(preview.entryCount == 3)
    #expect(preview.logicalBytes == 17)
    #expect(FileManager.default.fileExists(atPath: f.root.path))
    #expect(!FileManager.default.fileExists(atPath: f.project.appendingPathComponent(SmartSweep.recoveryFolderName).path))
    let driver = SmartSweep(), recovery = try await driver.stage(approved: preview)
    #expect(!FileManager.default.fileExists(atPath: f.root.path))
    #expect(try String(contentsOf: recovery.payloadURL.appendingPathComponent("package/file.txt"), encoding: .utf8) == "generated payload")
    #expect(recovery.state == "staged")
    let loaded = try SmartSweep.recoveries(under: f.project)
    #expect(loaded.count == 1)
    try await driver.putBack(approved: loaded[0])
    #expect(try String(contentsOf: f.root.appendingPathComponent("package/file.txt"), encoding: .utf8) == "generated payload")
    #expect(try SmartSweep.recoveries(under: f.project)[0].state == "restored")
}
@Test func sweepNeedsDependencyAcknowledgmentAndSeparatePermanentApproval() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("generated.txt")
    await #expect(throws: (any Error).self) { try await SmartSweep().preview(root: f.root, kind: .nodeModules) }
    let recovery = try await f.staged()
    await #expect(throws: (any Error).self) { try await SmartSweep().purge(approved: recovery) }
    #expect(FileManager.default.fileExists(atPath: recovery.payloadURL.path))
    let cleaned = try await SmartSweep().purge(approved: recovery, permanentlyDeleteAcknowledged: true)
    #expect(cleaned.removedEntries == recovery.entryCount)
    #expect(cleaned.estimatedAllocatedBytes == recovery.estimatedAllocatedBytes)
    #expect(!FileManager.default.fileExists(atPath: recovery.payloadURL.path))
    #expect(try SmartSweep.recoveries(under: f.project)[0].state == "purged")
}
@Test func sweepRefusesUnknownRootMissingLockAndOrdinaryFileSafetyStillProtectsCaches() async throws {
    let f = try SweepFixture(); defer { f.clean() }
    await #expect(throws: (any Error).self) { try await SmartSweep().preview(root: f.project, kind: .nodeModules, dependencyEditsAcknowledged: true) }
    try FileManager.default.removeItem(at: f.project.appendingPathComponent("package-lock.json"))
    await #expect(throws: (any Error).self) { try await f.preview() }
    let cache = f.base.appendingPathComponent("Library/Caches/pip/wheels")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try FileSafety().validatePolicy(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/pip/wheels"), root: FileManager.default.homeDirectoryForCurrentUser) }
    #expect(throws: (any Error).self) { try FileSafety().validate(f.project.appendingPathComponent("node_modules"), root: f.project) }
    #expect(try await SmartSweep().preview(root: cache, kind: .pipCache).entryCount == 1)
}
@Test func sweepPositiveKnownMarkersAcceptOnlyDerivedSubroots() async throws {
    let f = try SweepFixture(); defer { f.clean() }
    try Data("// generated test package".utf8).write(to: f.project.appendingPathComponent("Package.swift"))
    let build = f.project.appendingPathComponent(".build/arm64-apple-macosx/debug")
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    #expect(try await SmartSweep().preview(root: build, kind: .swiftPMBuild).entryCount == 1)
    await #expect(throws: (any Error).self) { try await SmartSweep().preview(root: f.project.appendingPathComponent(".build"), kind: .swiftPMBuild) }
    let xcode = f.base.appendingPathComponent("Library/Developer/Xcode/DerivedData/Generated/Build/Products")
    try FileManager.default.createDirectory(at: xcode, withIntermediateDirectories: true)
    try Data("generated plist marker".utf8).write(to: xcode.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("info.plist"))
    #expect(try await SmartSweep().preview(root: xcode, kind: .xcodeBuildProducts).entryCount == 1)
    let modules = f.base.appendingPathComponent("Library/Developer/Xcode/DerivedData/ModuleCache.noindex")
    try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
    #expect(try await SmartSweep().preview(root: modules, kind: .moduleCache).entryCount == 1)
}
@Test func sweepNpmCacheStagesAndRestoresWithoutOriginalMarkersBeingPresent() async throws {
    let f = try SweepFixture(); defer { f.clean() }
    let cache = f.base.appendingPathComponent(".npm/_cacache")
    for name in ["content-v2", "index-v5"] { try FileManager.default.createDirectory(at: cache.appendingPathComponent(name), withIntermediateDirectories: true) }
    try Data("generated cached bytes".utf8).write(to: cache.appendingPathComponent("content-v2/generated"))
    let driver = SmartSweep(), preview = try await driver.preview(root: cache, kind: .npmCache), recovery = try await driver.stage(approved: preview)
    try await driver.putBack(approved: recovery)
    #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("content-v2/generated").path))
}
@Test func sweepRefusesProtectedRootsAndCloudNamesAndRootSymlinks() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a")
    await #expect(throws: (any Error).self) { try await f.preview(SmartSweep(protectedRoots: [f.root.appendingPathComponent("a")])) }
    await #expect(throws: (any Error).self) { try await f.preview(SmartSweep(protectedRoots: [f.project])) }
    let cloud = f.base.appendingPathComponent("CloudStorage/pip/wheels")
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await SmartSweep().preview(root: cloud, kind: .pipCache) }
    let linked = f.base.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: f.project)
    await #expect(throws: (any Error).self) { try await SmartSweep().preview(root: linked.appendingPathComponent("node_modules"), kind: .nodeModules, dependencyEditsAcknowledged: true) }
}
@Test func sweepNodeSymlinksAreInventoriedWithoutFollowingExternalTargets() async throws {
    let f = try SweepFixture(); defer { f.clean() }
    let external = f.base.appendingPathComponent("outside.txt"); try Data("must survive".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("linked"), withDestinationURL: external)
    try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent("loop").path, withDestinationPath: ".")
    let preview = try await f.preview(); #expect(preview.symbolicLinkCount == 2); #expect(preview.logicalBytes == 0)
    let recovery = try await SmartSweep().stage(approved: preview)
    _ = try await SmartSweep().purge(approved: recovery, permanentlyDeleteAcknowledged: true)
    #expect(try String(contentsOf: external, encoding: .utf8) == "must survive")
}
@Test func sweepHardLinksDoNotDoubleCountOrClaimFreedExternalBlocks() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a", String(repeating: "x", count: 8192))
    #expect(link(f.root.appendingPathComponent("a").path, f.root.appendingPathComponent("b").path) == 0)
    let preview = try await f.preview(); #expect(preview.logicalBytes == 8192); #expect(preview.estimatedAllocatedBytes == 0); #expect(preview.sharedInodesExcluded == 1)
    let recovery = try await SmartSweep().stage(approved: preview)
    await #expect(throws: (any Error).self) { try await SmartSweep().purge(approved: recovery, permanentlyDeleteAcknowledged: true) }
    try await SmartSweep().putBack(approved: recovery)
    var a = stat(), b = stat(); #expect(lstat(f.root.appendingPathComponent("a").path, &a) == 0); #expect(lstat(f.root.appendingPathComponent("b").path, &b) == 0); #expect(a.st_ino == b.st_ino)
}
@Test func sweepNewAndChangedFilesInvalidatePreviewAndPurgeWithoutDeletion() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a", "old")
    let preview = try await f.preview(); try f.write("a", "new")
    await #expect(throws: (any Error).self) { try await SmartSweep().stage(approved: preview) }
    #expect(try String(contentsOf: f.root.appendingPathComponent("a"), encoding: .utf8) == "new")
    let recovery = try await f.staged(); try Data("unknown".utf8).write(to: recovery.payloadURL.appendingPathComponent("new.txt"))
    await #expect(throws: (any Error).self) { try await SmartSweep().purge(approved: recovery, permanentlyDeleteAcknowledged: true) }
    #expect(FileManager.default.fileExists(atPath: recovery.payloadURL.appendingPathComponent("a").path))
    try await SmartSweep().putBack(approved: recovery)
    #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.txt").path))
}
@Test func sweepRestorationNeverOverwritesRegeneratedOriginalPath() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a", "original")
    let recovery = try await f.staged()
    try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true); try f.write("a", "regenerated")
    await #expect(throws: (any Error).self) { try await SmartSweep().putBack(approved: recovery) }
    #expect(try String(contentsOf: f.root.appendingPathComponent("a"), encoding: .utf8) == "regenerated")
    #expect(try String(contentsOf: recovery.payloadURL.appendingPathComponent("a"), encoding: .utf8) == "original")
}
@Test func sweepUnsafeDatabaseMetadataSocketsAndSharedPermissionsAreRefused() async throws {
    for name in ["cache.db", "PG_VERSION", ".git", "opaque"] {
        let f = try SweepFixture(); defer { f.clean() }
        try f.write(name, name == "opaque" ? "SQLite format 3\0remainder" : "generated")
        await #expect(throws: (any Error).self) { try await f.preview() }
    }
    let f = try SweepFixture(); defer { f.clean() }; try f.write("shared")
    #expect(chmod(f.root.appendingPathComponent("shared").path, 0o666) == 0)
    await #expect(throws: (any Error).self) { try await f.preview() }
    #expect(chmod(f.root.appendingPathComponent("shared").path, 0o600) == 0)
    #expect(mkfifo(f.root.appendingPathComponent("fifo").path, 0o600) == 0)
    await #expect(throws: (any Error).self) { try await f.preview() }
}
@Test func sweepBudgetsAndCancellationNeverProduceAnApprovedPartialScan() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a", "generated bytes"); try f.write("nested/b")
    var limits = SmartSweepLimits(); limits.maximumEntries = 1
    await #expect(throws: (any Error).self) { try await f.preview(SmartSweep(limits: limits)) }
    limits = SmartSweepLimits(); limits.maximumBytes = 1
    await #expect(throws: (any Error).self) { try await f.preview(SmartSweep(limits: limits)) }
    limits = SmartSweepLimits(); limits.maximumDepth = 1; try f.write("nested/deeper/c")
    await #expect(throws: (any Error).self) { try await f.preview(SmartSweep(limits: limits)) }
    limits = SmartSweepLimits(); limits.scanTimeout = 0.0000001
    await #expect(throws: (any Error).self) { try await f.preview(SmartSweep(limits: limits)) }
    let task = Task { try await f.preview() }; task.cancel()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(FileManager.default.fileExists(atPath: f.root.path))
    #expect(try SmartSweep.recoveries(under: f.project).isEmpty)
}
@Test func sweepOpenFileAndProjectBuildProcessRefuseStaging() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a", "generated")
    let reader = Process(); reader.executableURL = URL(fileURLWithPath: "/usr/bin/tail"); reader.arguments = ["-f", f.root.appendingPathComponent("a").path]; reader.standardOutput = FileHandle.nullDevice; reader.standardError = FileHandle.nullDevice
    try reader.run(); defer { if reader.isRunning { reader.terminate(); reader.waitUntilExit() } }; usleep(100_000)
    await #expect(throws: (any Error).self) { try await f.preview() }
    reader.terminate(); reader.waitUntilExit()
    let executable = f.base.appendingPathComponent("swift-qa-sleeper")
    // A copied SIP-protected /bin/sleep can be killed by macOS signature policy.
    // Compile our own disposable process so this checks a genuinely running,
    // predictably named project build process rather than an already exited one.
    let source = f.base.appendingPathComponent("process.c")
    try Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8).write(to: source)
    let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = [source.path, "-o", executable.path]
    compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
    try compiler.run(); compiler.waitUntilExit(); #expect(compiler.terminationStatus == 0)
    let build = Process(); build.executableURL = executable; build.arguments = ["30"]; build.currentDirectoryURL = f.project; build.standardOutput = FileHandle.nullDevice; build.standardError = FileHandle.nullDevice
    try build.run(); defer { if build.isRunning { build.terminate(); build.waitUntilExit() } }; usleep(100_000)
    #expect(build.isRunning)
    await #expect(throws: (any Error).self) { try await f.preview() }
}
@Test func sweepRecoveryLeasesAndTamperedJournalsRefuseConcurrentOrStaleApproval() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a")
    let recovery = try await f.staged(), catalog = recovery.directory.deletingLastPathComponent()
    do {
        let lease = try OperationLease.acquire(catalogDirectory: catalog, jobID: recovery.id)
        await #expect(throws: (any Error).self) { try await SmartSweep().purge(approved: recovery, permanentlyDeleteAcknowledged: true) }
        withExtendedLifetime(lease) {}
    }
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: recovery.journalURL)) as! [String: Any]
    object["state"] = "uncertain"
    try JSONSerialization.data(withJSONObject: object).write(to: recovery.journalURL)
    await #expect(throws: (any Error).self) { try await SmartSweep().purge(approved: recovery, permanentlyDeleteAcknowledged: true) }
    let fresh = try SmartSweep.recoveries(under: f.project)[0]
    await #expect(throws: (any Error).self) { try await SmartSweep().purge(approved: fresh, permanentlyDeleteAcknowledged: true) }
    try await SmartSweep().putBack(approved: fresh)
}
@Test func sweepInterruptedPurgeRetainsRemainderAndNeverAutomaticallyResumes() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a"); try f.write("b"); try f.write("c")
    let recovery = try await f.staged()
    let cleanup = Task {
        try await SmartSweep().purge(approved: recovery, permanentlyDeleteAcknowledged: true) { _ in withUnsafeCurrentTask { $0?.cancel() } }
    }
    await #expect(throws: CancellationError.self) { try await cleanup.value }
    let fresh = try SmartSweep.recoveries(under: f.project)[0]
    #expect(fresh.state == "purgeStarted")
    #expect(FileManager.default.fileExists(atPath: fresh.payloadURL.path))
    await #expect(throws: (any Error).self) { try await SmartSweep().purge(approved: fresh, permanentlyDeleteAcknowledged: true) }
}
@Test func sweepRecoveryPermissionsArePrivateAndUnknownMembersAreNotDeleted() async throws {
    let f = try SweepFixture(); defer { f.clean() }; try f.write("a"); try f.write("b")
    let recovery = try await f.staged()
    var job = stat(), journal = stat()
    #expect(lstat(recovery.directory.path, &job) == 0); #expect(job.st_mode & 0o777 == 0o700)
    #expect(lstat(recovery.journalURL.path, &journal) == 0); #expect(journal.st_mode & 0o777 == 0o600)
    let unknown = recovery.payloadURL.appendingPathComponent("added-during-cleanup")
    await #expect(throws: (any Error).self) {
        try await SmartSweep().purge(approved: recovery, permanentlyDeleteAcknowledged: true) { _ in try? Data("retain unknown".utf8).write(to: unknown) }
    }
    #expect(try String(contentsOf: unknown, encoding: .utf8) == "retain unknown")
}
