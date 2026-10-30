import Testing
import Foundation
@testable import CloudNestCore

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ScanProgress] = []
    func append(_ value: ScanProgress) { lock.lock(); defer { lock.unlock() }; updates.append(value) }
    var values: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return updates }
}

@Test func scanProgressIsBoundedAndMatchesCompletedReport() throws {
    let f = try Fixture(); defer { f.clean() }
    let root = f.base.appendingPathComponent("scan-progress")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    for index in 0..<600 { try Data([42]).write(to: root.appendingPathComponent("file-\(index).txt")) }
    let log = ProgressLog()
    let report = try FileScanner().scan(root: root, minimumBytes: 0, onProgress: { log.append($0) })
    #expect(report.candidates.count == 600)
    #expect(report.visited == 600)
    #expect(log.values.count == 3)
    #expect(log.values.last?.matched == report.candidates.count)
    #expect(log.values.last?.visited == report.visited)
    let bounded = try FileScanner().scan(root: root, minimumBytes: 0, limit: 5)
    #expect(bounded.candidates.count == 5)
    #expect(bounded.truncated)
}

@Test func cancelledScanDoesNotPublishCompletedRecommendations() async throws {
    let f = try Fixture(); defer { f.clean() }
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try FileScanner().scan(root: f.base, minimumBytes: 0)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func excludedFilesDoNotHideLaterNestedScannerResults() throws {
    let f = try Fixture(); defer { f.clean() }
    let root = f.base.appendingPathComponent("scan-exclusions")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try Data("blocked database".utf8).write(to: root.appendingPathComponent("active.sqlite"))
    try Data("nested candidate".utf8).write(to: root.appendingPathComponent("nested/note.txt"))
    try Data().write(to: root.appendingPathComponent("zero%_literal.bin"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("symlink.txt"), withDestinationURL: root.appendingPathComponent("nested/note.txt"))
    let report = try FileScanner().scan(root: root, minimumBytes: 0)
    #expect(Set(report.candidates.map(\.url.lastPathComponent)) == ["note.txt", "zero%_literal.bin"])
    #expect(report.excluded == 2)
}

@Test func fileRestoreChecksFinalProtectedAndExcludedNames() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    let complete = try await f.catalog.job(job.id)
    let manifest = ArchiveManifest(job: complete, driveFileID: complete.remoteID!)
    let destination = f.base.appendingPathComponent("restore-policy")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let protected = ArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets,
        safety: FileSafety(protectedRoots: [destination.appendingPathComponent(manifest.fileName)]))
    await #expect(throws: (any Error).self) { try await protected.restore(manifest: manifest, destination: destination) }
    var object = try JSONSerialization.jsonObject(with: manifest.encoded()) as! [String: Any]
    object["fileName"] = "active.sqlite"
    let forged = try ArchiveManifest.decode(JSONSerialization.data(withJSONObject: object))
    await #expect(throws: (any Error).self) { try await f.coordinator.restore(manifest: forged, destination: destination) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
}
