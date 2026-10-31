import Testing
import Foundation
import Network
@testable import CloudNestCore

private actor ArchiveBridgeSecrets: SecretStore {
    var keys: [String] = []
    var value: Data
    init(origin: String) throws { value = try JSONEncoder().encode(["origin": origin, "token": String(repeating: "f", count: 64)]) }
    func changeOrigin(_ origin: String) throws { value = try JSONEncoder().encode(["origin": origin, "token": String(repeating: "g", count: 64)]) }
    func read(_ key: String) -> Data? { keys.append(key); return key == "brain-owner-connection" ? value : nil }
    func write(_ key: String, value: Data) throws { throw NestError.credentialUnavailable }
    func remove(_ key: String) throws { throw NestError.credentialUnavailable }
}
private final class ArchiveHTTPFixture: @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var response: Data = Data("{\"archives\":[],\"cursor\":null}".utf8)
    func reply(_ request: URLRequest) -> Data {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while body.count <= 65536 { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
            recorded.httpBody = body
        }
        lock.lock(); defer { lock.unlock() }; requests.append(recorded); return response
    }
    func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func body(_ data: Data) { lock.lock(); defer { lock.unlock() }; response = data }
}
private final class ArchiveHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock(); private var fixtures: [String: ArchiveHTTPFixture] = [:]
    func set(_ host: String, _ fixture: ArchiveHTTPFixture) { lock.lock(); defer { lock.unlock() }; fixtures[host] = fixture }
    func get(_ host: String) -> ArchiveHTTPFixture? { lock.lock(); defer { lock.unlock() }; return fixtures[host] }
}
private final class ArchiveHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = ArchiveHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { fixtures.get(request.url?.host ?? "") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.fixtures.get(url.host ?? ""), let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.reply(request)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class ArchiveRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cloudnest.test.archive-redirect")
    private let lock = NSLock(); private var hits = 0
    let location: String?
    var port: UInt16 { listener.port!.rawValue }
    var count: Int { lock.lock(); defer { lock.unlock() }; return hits }
    init(location: String? = nil) throws {
        self.location = location
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }; connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] _, _, _, _ in
                guard let self else { connection.cancel(); return }
                self.lock.lock(); self.hits += 1; self.lock.unlock()
                let response = self.location.map { "HTTP/1.1 302 Found\r\nLocation: \($0)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" } ?? "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success else { listener.cancel(); throw NestError.invalidResponse }
    }
    func stop() { listener.cancel() }
}

@Test func brainArchiveFactoryRequiresFreshMatchingHealthyStandaloneJobAndPublishesNoPaths() async throws {
    let f = try Fixture(); defer { f.clean() }
    let queued = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base); try await f.coordinator.run(queued.id)
    var job = try await f.catalog.job(queued.id)
    let now = Date(), health = ArchiveHealthReport(jobID: job.id, status: .healthy, checkedAt: now, detail: "fixture")
    let record = try BrainArchivePublication.verifiedFile(job, health: health, now: now)
    let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    #expect(record.name == job.source.lastPathComponent && record.localState == .unknown)
    #expect(!encoded.contains(job.source.path) && !encoded.contains("approvedRoot") && !encoded.contains("session"))
    #expect(throws: (any Error).self) { try BrainArchivePublication.verifiedFile(job, health: health, now: now.addingTimeInterval(301)) }
    #expect(throws: (any Error).self) { try BrainArchivePublication.verifiedFile(job, health: ArchiveHealthReport(jobID: UUID(), status: .healthy, checkedAt: now, detail: "fixture"), now: now) }
    #expect(throws: (any Error).self) { try BrainArchivePublication.verifiedFile(job, health: ArchiveHealthReport(jobID: job.id, status: .mismatch, checkedAt: now, detail: "fixture"), now: now) }
    job.folderArchiveID = UUID()
    #expect(throws: (any Error).self) { try BrainArchivePublication.verifiedFile(job, health: health, now: now) }
}

@Test func brainFolderPublicationUsesActualManifestIDAndRefusesSummary() async throws {
    let f = try Fixture(); defer { f.clean() }
    let source = f.base.appendingPathComponent("Project"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("disposable".utf8).write(to: source.appendingPathComponent("readme.txt"))
    let coordinator = FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets)
    let pending = try await coordinator.enqueue(source: source, approvedRoot: source); try await coordinator.run(pending.id)
    let complete = try await coordinator.job(pending.id), health = await coordinator.health(pending.id)
    let record = try BrainArchivePublication.verifiedFolder(complete, health: health)
    #expect(record.driveTarget == .manifest && record.driveFileId == complete.remoteManifestID && record.driveFileId == record.manifestFileId)
    #expect(record.fileCount == 1 && record.bytes == 10 && record.sha256?.count == 64)
    #expect(throws: (any Error).self) { try BrainArchivePublication.verifiedFolder(complete.summary, health: health) }
}

@Test func brainArchiveOriginValidationRefusesCredentialAndPathConfusion() throws {
    for origin in ["http://example.invalid", "https://user:pass@example.invalid", "https://example.invalid/path", "https://example.invalid?token=x", "https://example.invalid#fragment", "file:///tmp", "http://localhost.example.invalid", "http://127.1"] { #expect(throws: (any Error).self) { try BrainArchiveCatalog.validateOrigin(origin) } }
    for origin in ["https://brain.example.invalid", "http://127.0.0.1:8787", "http://localhost:8787", "http://[::1]:8787"] { _ = try BrainArchiveCatalog.validateOrigin(origin) }
}

@Test func brainArchiveBridgeReadsOnlyBrainCredentialAndNeverSerializesMacPaths() async throws {
    let f = try Fixture(); defer { f.clean() }
    let queued = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base); try await f.coordinator.run(queued.id)
    let job = try await f.catalog.job(queued.id)
    let health = await ArchiveHealthChecker(remote: f.remote).check(job)
    let record = try BrainArchivePublication.verifiedFile(job, health: health)
    let host = "archive-" + UUID().uuidString.lowercased() + ".example.invalid", fixture = ArchiveHTTPFixture()
    ArchiveHTTPProtocol.fixtures.set(host, fixture)
    let secrets = try ArchiveBridgeSecrets(origin: "https://" + host), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArchiveHTTPProtocol.self]
    let bridge = BrainArchiveCatalog(secrets: secrets, configuration: config)
    var published = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    published["project"] = "project"; published["visibility"] = "private"; published["publishedAt"] = record.checkedAt
    published["driveURL"] = "https://drive.google.com/file/d/" + record.driveFileId + "/view"
    published["manifestURL"] = "https://drive.google.com/file/d/" + record.manifestFileId + "/view"
    fixture.body(try JSONSerialization.data(withJSONObject: ["archives": [published]]))
    _ = try await bridge.publish(project: "project", archives: [record])
    fixture.body(Data("{\"archives\":[],\"cursor\":null}".utf8))
    _ = try await bridge.list(query: "name &?fragment")
    let requests = fixture.captured(); #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/api/v1/archives/publish")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "f", count: 64))
    #expect(requests.allSatisfy { $0.url?.host == host && $0.url?.query?.contains(String(repeating: "f", count: 64)) != true })
    let body = try #require(requests[0].httpBody), object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["visibility"] as? String == "private")
    #expect(!String(decoding: body, as: UTF8.self).contains(job.source.path))
    #expect(await secrets.keys == ["brain-owner-connection", "brain-owner-connection"])
}

@Test func brainArchiveBridgeBoundsResponsesAndRejectsUnsafeDriveViewerLinks() async throws {
    let host = "archive-" + UUID().uuidString.lowercased() + ".example.invalid", fixture = ArchiveHTTPFixture()
    ArchiveHTTPProtocol.fixtures.set(host, fixture); fixture.body(Data(repeating: 32, count: 524289))
    let secrets = try ArchiveBridgeSecrets(origin: "https://" + host), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArchiveHTTPProtocol.self]
    let bridge = BrainArchiveCatalog(secrets: secrets, configuration: config)
    await #expect(throws: (any Error).self) { try await bridge.list() }
    let record: [String: Any] = ["id": UUID().uuidString, "project": "project", "visibility": "approved", "name": "File", "kind": "file", "bytes": 1, "driveFileId": "fixture-file", "manifestFileId": "fixture-manifest", "driveTarget": "file", "checkedAt": "2026-01-01T00:00:00Z", "localState": "unknown", "publishedAt": "2026-01-01T00:00:00Z", "driveURL": "https://example.invalid/steal", "manifestURL": "https://drive.google.com/file/d/fixture-manifest/view"]
    fixture.body(try JSONSerialization.data(withJSONObject: ["archives": [record]]))
    await #expect(throws: (any Error).self) { try await bridge.list() }
}

@Test func brainArchiveBridgeDeniesCrossOriginRedirectWithoutForwardingCredential() async throws {
    let destination = try ArchiveRedirectServer(); defer { destination.stop() }
    let origin = try ArchiveRedirectServer(location: "http://127.0.0.1:\(destination.port)/credential-must-not-arrive"); defer { origin.stop() }
    let bridge = BrainArchiveCatalog(secrets: try ArchiveBridgeSecrets(origin: "http://127.0.0.1:\(origin.port)"))
    await #expect(throws: (any Error).self) { try await bridge.list() }
    #expect(origin.count == 1 && destination.count == 0)
}

private func publishedFixture(_ publication: BrainArchivePublication, edits: [String: Any] = [:]) throws -> BrainPublishedArchive {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(publication)) as? [String: Any])
    object["project"] = "project"; object["visibility"] = "private"; object["publishedAt"] = publication.checkedAt
    object["driveURL"] = "https://drive.google.com/" + (publication.driveTarget == .folder ? "drive/folders/" + publication.driveFileId : "file/d/" + publication.driveFileId + "/view")
    object["manifestURL"] = "https://drive.google.com/file/d/" + publication.manifestFileId + "/view"
    object.merge(edits) { _, new in new }
    return try JSONDecoder().decode(BrainPublishedArchive.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func brainArchiveReviewedOriginMismatchMakesZeroPublicationRequests() async throws {
    let f = try Fixture(); defer { f.clean() }
    let queued = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base); try await f.coordinator.run(queued.id)
    let job = try await f.catalog.job(queued.id), health = await ArchiveHealthChecker(remote: f.remote).check(try await f.catalog.job(queued.id))
    let record = try BrainArchivePublication.verifiedFile(job, health: health)
    let oldHost = "reviewed-" + UUID().uuidString.lowercased() + ".example.invalid", newHost = "changed-" + UUID().uuidString.lowercased() + ".example.invalid"
    let fixture = ArchiveHTTPFixture(), oldFixture = ArchiveHTTPFixture()
    ArchiveHTTPProtocol.fixtures.set(newHost, fixture); ArchiveHTTPProtocol.fixtures.set(oldHost, oldFixture)
    let secrets = try ArchiveBridgeSecrets(origin: "https://" + oldHost), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArchiveHTTPProtocol.self]
    let reviewed = try await BrainArchiveCatalog(secrets: secrets, configuration: config).configuredOrigin()
    // The owner reviewed the old origin, then another settings action changed the
    // paired Keychain recipient/credential while archive health was being checked.
    try await secrets.changeOrigin("https://" + newHost)
    let bridge = BrainArchiveCatalog(secrets: secrets, configuration: config, expectedOrigin: reviewed)
    await #expect(throws: (any Error).self) { try await bridge.publish(project: "project", archives: [record]) }
    #expect(fixture.captured().isEmpty && oldFixture.captured().isEmpty)
    #expect(await secrets.keys == ["brain-owner-connection", "brain-owner-connection"])
}

@Test func brainArchiveReviewedOriginUsesExactHostSchemeAndEffectivePort() async throws {
    let host = "archive-" + UUID().uuidString.lowercased() + ".example.invalid", fixture = ArchiveHTTPFixture()
    ArchiveHTTPProtocol.fixtures.set(host, fixture)
    let secrets = try ArchiveBridgeSecrets(origin: "https://" + host), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArchiveHTTPProtocol.self]
    let reviewed = try #require(URL(string: "https://" + host + ":443/"))
    _ = try await BrainArchiveCatalog(secrets: secrets, configuration: config, expectedOrigin: reviewed).list()
    #expect(fixture.captured().count == 1)
    let wrongPort = try #require(URL(string: "https://" + host + ":444"))
    await #expect(throws: (any Error).self) { try await BrainArchiveCatalog(secrets: secrets, configuration: config, expectedOrigin: wrongPort).list() }
    #expect(fixture.captured().count == 1)
}

@Test func brainFileRestoreManifestMustMatchPublishedIdentityBytesAndChecksum() async throws {
    let f = try Fixture(); defer { f.clean() }
    let queued = try await f.coordinator.enqueue(source: f.source, approvedRoot: f.base); try await f.coordinator.run(queued.id)
    let job = try await f.catalog.job(queued.id), health = await ArchiveHealthChecker(remote: f.remote).check(try await f.catalog.job(queued.id))
    let publication = try BrainArchivePublication.verifiedFile(job, health: health), published = try publishedFixture(publication)
    let manifest = ArchiveManifest(job: job, driveFileID: try #require(job.remoteID)); try published.validateRestoreManifest(manifest)
    for edits: [String: Any] in [["id": UUID().uuidString], ["bytes": publication.bytes + 1], ["sha256": String(repeating: "a", count: 64)], ["driveFileId": "changed-file-id"], ["kind": "folder"], ["driveTarget": "manifest"], ["sha256": NSNull()]] {
        let changed = try publishedFixture(publication, edits: edits)
        #expect(throws: (any Error).self) { try changed.validateRestoreManifest(manifest) }
    }
}

@Test func brainFolderRestoreBindsValidRootDigestCountBytesAndIdentityEvenAtSameDriveID() async throws {
    let f = try Fixture(); defer { f.clean() }
    let source = f.base.appendingPathComponent("Folder"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("fixture".utf8).write(to: source.appendingPathComponent("note.txt"))
    let coordinator = FolderArchiveCoordinator(catalog: f.catalog, remote: f.remote, secrets: f.secrets)
    let pending = try await coordinator.enqueue(source: source, approvedRoot: source); try await coordinator.run(pending.id)
    let job = try await coordinator.job(pending.id), health = await coordinator.health(pending.id)
    let root = try #require(job.manifest), publication = try BrainArchivePublication.verifiedFolder(job, health: health), published = try publishedFixture(publication)
    try published.validateRestoreManifest(root)
    // Both roots are structurally valid and use the same archive UUID/member Drive
    // IDs, byte count and file count. A changed root must still fail its digest.
    let changedRoot = FolderArchiveManifest(id: root.id, folderName: "Renamed folder", createdAt: root.createdAt, directories: root.directories, files: root.files, metadata: root.metadata)
    try changedRoot.validate()
    #expect(throws: (any Error).self) { try published.validateRestoreManifest(changedRoot) }
    let changedID = FolderArchiveManifest(id: UUID(), folderName: root.folderName, createdAt: root.createdAt, directories: root.directories, files: root.files, metadata: root.metadata)
    try changedID.validate()
    #expect(throws: (any Error).self) { try published.validateRestoreManifest(changedID) }
    let child = try #require(root.files.first)
    func changedChild(name: String, size: Int64) throws -> FolderArchiveFile {
        var object = try #require(JSONSerialization.jsonObject(with: child.manifest.encoded()) as? [String: Any])
        object["fileName"] = name; object["size"] = NSNumber(value: size)
        return FolderArchiveFile(relativePath: name, manifest: try ArchiveManifest.decode(JSONSerialization.data(withJSONObject: object)))
    }
    let resizedRoot = FolderArchiveManifest(id: root.id, folderName: root.folderName, createdAt: root.createdAt, directories: [], files: [try changedChild(name: child.relativePath, size: child.manifest.size + 1)], metadata: nil)
    try resizedRoot.validate()
    #expect(throws: (any Error).self) { try published.validateRestoreManifest(resizedRoot) }
    let extraFileRoot = FolderArchiveManifest(id: root.id, folderName: root.folderName, createdAt: root.createdAt, directories: [], files: root.files + [try changedChild(name: "extra-empty.txt", size: 0)], metadata: nil)
    try extraFileRoot.validate()
    #expect(throws: (any Error).self) { try published.validateRestoreManifest(extraFileRoot) }
    let overflowing = FolderArchiveManifest(id: root.id, folderName: root.folderName, createdAt: root.createdAt, directories: [], files: [try changedChild(name: "large.bin", size: Int64.max), try changedChild(name: "one.bin", size: 1)], metadata: nil)
    #expect(throws: (any Error).self) { try published.validateRestoreManifest(overflowing) }
    for edits: [String: Any] in [["bytes": publication.bytes + 1], ["fileCount": (publication.fileCount ?? 0) + 1], ["fileCount": NSNull()], ["sha256": NSNull()], ["driveTarget": "folder"], ["driveFileId": "different-root-id"], ["kind": "file"]] {
        let changed = try publishedFixture(publication, edits: edits)
        #expect(throws: (any Error).self) { try changed.validateRestoreManifest(root) }
    }
}
