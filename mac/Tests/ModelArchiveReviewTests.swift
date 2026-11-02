import Testing
import Foundation
import Darwin
@testable import CloudNestCore

/// Opens only a disposable sentinel after download has begun, so an initial
/// preflight cannot accidentally satisfy the final-install inactivity check.
private final class ModelRestoreLateReader: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var output: Pipe?
    private var observedReady = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return observedReady }
    func start(at sentinel: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard process == nil else { return }
        let command = Process(), pipe = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        command.arguments = ["-f", sentinel.path]
        command.standardInput = FileHandle.nullDevice
        command.standardOutput = pipe; command.standardError = FileHandle.nullDevice
        try command.run(); process = command; output = pipe
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var buffer = [UInt8](repeating: 0, count: 1024)
        while command.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { observedReady = true; return }
            if count < 0 && errno != EAGAIN && errno != EINTR { throw NestError.invalidResponse }
            usleep(10_000)
        }
        throw NestError.unsafePath("disposable reader did not open its fixture")
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        try? output?.fileHandleForReading.close()
        process = nil; output = nil
    }
    deinit { stop() }
}

private actor ModelRestoreReaderRemote: ArchiveRemote {
    let base: TestRemote
    let reader: ModelRestoreLateReader
    private var sentinel: URL?
    init(base: TestRemote, reader: ModelRestoreLateReader) { self.base = base; self.reader = reader }
    func arm(_ sentinel: URL) { self.sentinel = sentinel }
    func allocateID() async throws -> String { await base.allocateID() }
    func begin(id: String, name: String, size: Int64, jobID: UUID) async throws -> URL { await base.begin(id: id, name: name, size: size, jobID: jobID) }
    func status(session: URL, total: Int64) async throws -> UploadProgress { try await base.status(session: session, total: total) }
    func send(session: URL, data: Data, offset: Int64, total: Int64) async throws -> UploadProgress { try await base.send(session: session, data: data, offset: offset, total: total) }
    func metadata(id: String) async throws -> RemoteFile { try await base.metadata(id: id) }
    func storeManifest(_ manifest: ArchiveManifest) async throws -> String { try await base.storeManifest(manifest) }
    func download(id: String, into destination: FileHandle, maximumBytes: Int64) async throws {
        try await base.download(id: id, into: destination, maximumBytes: maximumBytes)
        if let sentinel { self.sentinel = nil; try reader.start(at: sentinel) }
    }
}

@Test func modelFolderChildrenRetainPurposeInReopenedCatalogAndPortableManifests() async throws {
    let f = try Fixture(); defer { f.clean() }
    let source = f.base.appendingPathComponent("portable-model")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("model weights".utf8).write(to: source.appendingPathComponent("weights.gguf"))
    try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
    let folders = FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets)
    let job = try await folders.enqueue(source: source, approvedRoot: source, purpose: .modelParking)
    let reopened = try Catalog(directory: f.base.appendingPathComponent("catalog"))
    let queued = try await reopened.jobs().filter { $0.folderArchiveID == job.id }
    #expect(queued.count == 2)
    #expect(queued.allSatisfy { $0.purpose == .modelParking })
    try await folders.run(job.id)
    let complete = try await folders.job(job.id)
    let manifest = try #require(complete.manifest)
    #expect(manifest.files.count == 2)
    #expect(manifest.files.allSatisfy { $0.manifest.purpose == .modelParking })
    for child in try await reopened.jobs().filter({ $0.folderArchiveID == job.id }) {
        #expect(child.state == .verified && child.purpose == .modelParking)
        let portable = try ArchiveManifest.read(from: f.base.appendingPathComponent("catalog/manifests/" + child.id.uuidString + ".json"))
        #expect(portable.purpose == .modelParking)
    }
}

@Test func modelFileRestoreRechecksLateReaderBeforePublishingTarget() async throws {
    let f = try Fixture(); defer { f.clean() }
    let reader = ModelRestoreLateReader(); defer { reader.stop() }
    let remote = ModelRestoreReaderRemote(base: f.remote, reader: reader)
    let coordinator = ArchiveCoordinator(catalog: f.catalog, remote: remote, secrets: f.secrets)
    let job = try await coordinator.enqueue(source: f.source, approvedRoot: f.base, purpose: .modelParking)
    try await coordinator.run(job.id)
    let complete = try await f.catalog.job(job.id)
    let manifest = ArchiveManifest(job: complete, driveFileID: try #require(complete.remoteID))
    let destination = f.base.appendingPathComponent("restore-destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let sentinel = destination.appendingPathComponent("existing-user-data.txt")
    let sentinelData = Data("existing fixture content\n".utf8)
    try sentinelData.write(to: sentinel)
    await remote.arm(sentinel)
    await #expect(throws: (any Error).self) { try await coordinator.restore(manifest: manifest, destination: destination) }
    #expect(reader.started)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(manifest.fileName).path))
    #expect(try Data(contentsOf: sentinel) == sentinelData)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [sentinel.lastPathComponent])
    #expect(try Data(contentsOf: f.source) == Data(repeating: 0xA7, count: 1024))
}

@Test func modelFolderRestoreRechecksLateReaderInFinalDestinationParent() async throws {
    let f = try Fixture(); defer { f.clean() }
    let reader = ModelRestoreLateReader(); defer { reader.stop() }
    let remote = ModelRestoreReaderRemote(base: f.remote, reader: reader)
    let source = f.base.appendingPathComponent("model-export")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("verified model weights".utf8).write(to: source.appendingPathComponent("weights.gguf"))
    let folders = FolderArchiveCoordinator(catalog: f.catalog, remote: remote, secrets: f.secrets)
    let job = try await folders.enqueue(source: source, approvedRoot: source, purpose: .modelParking)
    try await folders.run(job.id)
    let manifest = try #require(await folders.job(job.id).manifest)
    let destination = f.base.appendingPathComponent("folder-restore-destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    // This sibling is outside the private child staging directory. Child-level
    // checks cannot substitute for checking the final folder's parent again.
    let sentinel = destination.appendingPathComponent("existing-user-data.txt")
    let sentinelData = Data("existing fixture content\n".utf8)
    try sentinelData.write(to: sentinel)
    await remote.arm(sentinel)
    await #expect(throws: (any Error).self) { try await folders.restore(manifest: manifest, destination: destination) }
    #expect(reader.started)
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(manifest.folderName).path))
    #expect(try Data(contentsOf: sentinel) == sentinelData)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [sentinel.lastPathComponent])
    #expect(try Data(contentsOf: source.appendingPathComponent("weights.gguf")) == Data("verified model weights".utf8))
}
