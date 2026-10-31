import Testing
import Foundation
import CryptoKit
@testable import CloudNestCore

actor TestSecrets: SecretStore {
    private var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { values[key] }
    func write(_ key: String, value: Data) { values[key] = value }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}

actor TestRemote: ArchiveRemote {
    var objects: [String: Data] = [:]
    var partial: [String: Data] = [:]
    var sessionIDs: [URL: String] = [:]
    var interruptAfterAccept = false
    var omitChecksum = false
    var corruptManifest = false
    var corruptDownload = false
    var sentOffsets: [Int64] = []
    func configure(interrupt: Bool = false, omit: Bool = false, manifest: Bool = false, download: Bool = false) {
        interruptAfterAccept = interrupt; omitChecksum = omit; corruptManifest = manifest; corruptDownload = download
    }
    func allocateID() -> String { UUID().uuidString }
    func begin(id: String, name: String, size: Int64, jobID: UUID) -> URL {
        let url = URL(string: "https://www.googleapis.com/upload/test?session=" + id)!
        sessionIDs[url] = id; partial[id] = Data(); return url
    }
    func status(session: URL, total: Int64) throws -> UploadProgress {
        guard let id = sessionIDs[session], let bytes = partial[id] else { throw NestError.http(404) }
        return UploadProgress(offset: Int64(bytes.count), complete: objects[id] != nil)
    }
    func send(session: URL, data: Data, offset: Int64, total: Int64) throws -> UploadProgress {
        let id = sessionIDs[session]!
        guard Int64(partial[id]!.count) == offset else { throw NestError.invalidResponse }
        sentOffsets.append(offset); partial[id]!.append(data)
        let finished = Int64(partial[id]!.count) == total
        if finished { objects[id] = partial[id] }
        if interruptAfterAccept { interruptAfterAccept = false; throw NestError.http(503) }
        return UploadProgress(offset: Int64(partial[id]!.count), complete: finished)
    }
    func metadata(id: String) throws -> RemoteFile {
        guard let data = objects[id] else { throw NestError.http(404) }
        return RemoteFile(id: id, size: String(data.count), sha256Checksum: omitChecksum ? nil : Self.hash(data))
    }
    func storeManifest(_ manifest: ArchiveManifest) throws -> String {
        let id = UUID().uuidString
        objects[id] = corruptManifest ? Data("bad".utf8) : try manifest.encoded()
        return id
    }
    func download(id: String, into destination: FileHandle, maximumBytes: Int64) throws {
        guard let data = objects[id] else { throw NestError.http(404) }
        try destination.write(contentsOf: corruptDownload ? Data("bad download".utf8) : data)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct Fixture {
    let base: URL
    let source: URL
    let catalog: Catalog
    let remote = TestRemote()
    let secrets = TestSecrets()
    var coordinator: ArchiveCoordinator { ArchiveCoordinator(catalog: catalog, remote: remote, secrets: secrets) }
    init(size: Int = 1024) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Spotlight must not become an unrelated reader of these disposable workflow fixtures.
        // Keep the production file-in-use guard fully enforced, including for system readers.
        base = repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/tests-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        source = base.appendingPathComponent("original.bin")
        try Data(repeating: 0xA7, count: size).write(to: source)
        catalog = try Catalog(directory: base.appendingPathComponent("catalog"))
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
}

@Test func interruptedUploadResumesUsingRemoteOffsetAndRestores() async throws {
    let f = try Fixture(size: ArchiveCoordinator.chunkBytes * 2 + 123); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    await f.remote.configure(interrupt: true)
    await #expect(throws: (any Error).self) { try await f.coordinator.run(job.id) }
    let interrupted = try await f.catalog.job(job.id)
    #expect(interrupted.offset == 0)
    // New coordinator and connection model app termination/restart. Session survives separately.
    let reopened = try Catalog(directory: f.base.appendingPathComponent("catalog"))
    let restarted = ArchiveCoordinator(catalog: reopened, remote: f.remote, secrets: f.secrets)
    try await restarted.run(job.id)
    let result = try await reopened.job(job.id)
    #expect(result.state == .verified)
    #expect(await f.remote.sentOffsets == [0, Int64(ArchiveCoordinator.chunkBytes), Int64(ArchiveCoordinator.chunkBytes * 2)])
    #expect(FileManager.default.fileExists(atPath: f.source.path))
    let destination = f.base.appendingPathComponent("restored"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let manifest = ArchiveManifest(job: result, driveFileID: result.remoteID!)
    let restored = try await restarted.restore(manifest: manifest, destination: destination)
    #expect(try Data(contentsOf: restored) == Data(contentsOf: f.source))
    await #expect(throws: (any Error).self) { try await restarted.restore(manifest: manifest, destination: destination) }
}

@Test func lostFinalAcknowledgementDoesNotCreateDuplicate() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    await f.remote.configure(interrupt: true)
    await #expect(throws: (any Error).self) { try await f.coordinator.run(job.id) }
    try await f.coordinator.run(job.id)
    #expect(await f.remote.sentOffsets == [0])
    #expect(try await f.catalog.job(job.id).state == .verified)
}

@Test func missingRemoteChecksumNeverVerifies() async throws {
    let f = try Fixture(); defer { f.clean() }
    await f.remote.configure(omit: true)
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    await #expect(throws: (any Error).self) { try await f.coordinator.run(job.id) }
    #expect(try await f.catalog.job(job.id).state != .verified)
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func corruptRecoveryManifestNeverVerifies() async throws {
    let f = try Fixture(); defer { f.clean() }
    await f.remote.configure(manifest: true)
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    await #expect(throws: (any Error).self) { try await f.coordinator.run(job.id) }
    #expect(try await f.catalog.job(job.id).state != .verified)
    #expect(FileManager.default.fileExists(atPath: f.source.path))
}

@Test func changedSourceRefusesUpload() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try Data("changed".utf8).write(to: f.source)
    await #expect(throws: (any Error).self) { try await f.coordinator.run(job.id) }
    #expect(await f.remote.sentOffsets.isEmpty)
    #expect(try Data(contentsOf: f.source) == Data("changed".utf8))
}

@Test func corruptDownloadNeverInstalls() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    let complete = try await f.catalog.job(job.id)
    await f.remote.configure(download: true)
    let dest = f.base.appendingPathComponent("restore"); try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await f.coordinator.restore(manifest: ArchiveManifest(job: complete, driveFileID: complete.remoteID!), destination: dest) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
}

@Test func scannerDeduplicatesHardLinksAndExcludesUnsafePaths() throws {
    let f = try Fixture(); defer { f.clean() }
    let scan = f.base.appendingPathComponent("scan"); try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: false)
    let file = scan.appendingPathComponent("one.bin"); try Data(repeating: 1, count: 4096).write(to: file)
    try FileManager.default.linkItem(at: file, to: scan.appendingPathComponent("two.bin"))
    try FileManager.default.createSymbolicLink(at: scan.appendingPathComponent("link"), withDestinationURL: f.source)
    try Data("db".utf8).write(to: scan.appendingPathComponent("live.sqlite"))
    let repo = scan.appendingPathComponent("project/.git"); try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Data("repo".utf8).write(to: repo.deletingLastPathComponent().appendingPathComponent("source.swift"))
    let report = try FileScanner().scan(root: scan, minimumBytes: 0)
    #expect(report.candidates.count == 1)
    #expect(report.excluded >= 3)
    #expect(throws: (any Error).self) { try FileSafety(protectedRoots: [scan]).snapshot(file, root: scan) }
    #expect(throws: (any Error).self) { try FileSafety().snapshot(f.source, root: scan) }
}

@Test func traversalAndSymlinkDestinationsRejected() async throws {
    let f = try Fixture(); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    let manifest = ArchiveManifest(job: job, driveFileID: "remote-id")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
    object["fileName"] = "../escape"
    let invalid = try JSONDecoder().decode(ArchiveManifest.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: (any Error).self) { try invalid.validate() }
    let link = f.base.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.base)
    await #expect(throws: (any Error).self) { try await f.coordinator.restore(manifest: manifest, destination: link) }
}

@Test func emptyFileArchives() async throws {
    let f = try Fixture(size: 0); defer { f.clean() }
    let job = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base)
    try await f.coordinator.run(job.id)
    #expect(try await f.catalog.job(job.id).state == .verified)
}

@Test func pkceAndHttpSafety() throws {
    #expect(PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(throws: (any Error).self) { try PKCE.callbackCode("/callback?code=a&state=wrong", expectedState: "correct") }
    #expect(try PKCE.callbackCode("/callback?code=a&state=correct", expectedState: "correct") == "a")
    #expect(throws: (any Error).self) { try DriveClient.validateGoogleURL(URL(string: "https://www.googleapis.com.attacker.example/upload")!) }
    #expect(throws: (any Error).self) { try DriveClient.validateGoogleURL(URL(string: "http://www.googleapis.com/upload")!) }
    #expect(try DriveClient.acknowledgedOffset(range: "bytes=0-8388607", total: 20_000_000) == 8_388_608)
    #expect(throws: (any Error).self) { try DriveClient.acknowledgedOffset(range: "bytes=1-99", total: 100) }
    #expect(String(decoding: GoogleOAuth.form(["token": "a+b&c=d"]), as: UTF8.self) == "token=a%2Bb%26c%3Dd")
}
