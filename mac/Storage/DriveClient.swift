import Foundation

public struct UploadProgress: Sendable {
    public let offset: Int64
    public let complete: Bool
    public init(offset: Int64, complete: Bool) { self.offset = offset; self.complete = complete }
}

public protocol ArchiveRemote: Sendable {
    func allocateID() async throws -> String
    func begin(id: String, name: String, size: Int64, jobID: UUID) async throws -> URL
    func status(session: URL, total: Int64) async throws -> UploadProgress
    func send(session: URL, data: Data, offset: Int64, total: Int64) async throws -> UploadProgress
    func metadata(id: String) async throws -> RemoteFile
    func storeManifest(_ manifest: ArchiveManifest) async throws -> String
    func download(id: String, into destination: FileHandle, maximumBytes: Int64) async throws
}

// Reject redirects, including 308 upload acknowledgements. No bearer token is forwarded.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor DriveClient: ArchiveRemote {
    private let oauth: GoogleOAuth
    private let session: URLSession
    private var folderIDs: [String: String] = [:]
    public init(oauth: GoogleOAuth) {
        self.oauth = oauth
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    private func request(_ url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        try Self.validateGoogleURL(url)
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(try await oauth.accessToken())", forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NestError.invalidResponse }
        if let error = Self.actionableError(status: response.statusCode, data: data) { throw error }
        return (data, response)
    }
    /// Only map known provider reason codes. Never expose arbitrary response bodies in UI/logs.
    public static func actionableError(status: Int, data: Data) -> DriveServiceError? {
        if status == 429 { return .rateLimited }
        guard status == 403 else { return nil }
        struct Failure: Decodable {
            struct Details: Decodable {
                struct Reason: Decodable { let reason: String? }
                let errors: [Reason]?
            }
            let error: Details
        }
        let reasons = (try? JSONDecoder().decode(Failure.self, from: data).error.errors?.compactMap(\.reason)) ?? []
        if reasons.contains("storageQuotaExceeded") { return .quotaExceeded }
        if reasons.contains(where: { ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"].contains($0) }) { return .rateLimited }
        return nil
    }
    public func storageQuota() async throws -> DriveStorageQuota {
        let (data, response) = try await request(endpoint("about", ["fields": "storageQuota(limit,usage,usageInDrive,usageInDriveTrash)"]))
        guard response.statusCode == 200 else { throw NestError.http(response.statusCode) }
        return try DriveStorageQuota.decode(data)
    }
    public static func validateGoogleURL(_ url: URL) throws {
        guard url.scheme == "https", url.host == "www.googleapis.com", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else { throw NestError.invalidResponse }
    }
    private func endpoint(_ path: String, _ query: [String: String] = [:]) -> URL {
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/" + path)!
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    private func validID(_ id: String) throws {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw NestError.invalidManifest }
    }
    private func folder(role: String, name: String, parent: String? = nil) async throws -> String {
        if let id = folderIDs[role] { return id }
        let query = "trashed = false and mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='cloudnestRole' and value='\(role)' }" + (parent.map { " and '\($0)' in parents" } ?? "")
        let (data, response) = try await request(endpoint("files", ["q": query, "fields": "files(id)", "pageSize": "2"]))
        guard response.statusCode == 200 else { throw NestError.http(response.statusCode) }
        struct Listing: Decodable { let files: [ID] }; struct ID: Decodable { let id: String }
        let files = try JSONDecoder().decode(Listing.self, from: data).files
        guard files.count < 2 else { throw NestError.conflict }
        if let id = files.first?.id { folderIDs[role] = id; return id }
        var metadata: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder", "appProperties": ["cloudnestRole": role]]
        if let parent { metadata["parents"] = [parent] }
        let (created, result) = try await request(endpoint("files", ["fields": "id"]), method: "POST", body: JSONSerialization.data(withJSONObject: metadata), headers: ["Content-Type": "application/json"])
        guard result.statusCode == 200 || result.statusCode == 201 else { throw NestError.http(result.statusCode) }
        let id = try JSONDecoder().decode(ID.self, from: created).id; folderIDs[role] = id; return id
    }
    public func allocateID() async throws -> String {
        let (data, response) = try await request(endpoint("files/generateIds", ["count": "1", "space": "drive", "type": "files"]))
        guard response.statusCode == 200 else { throw NestError.http(response.statusCode) }
        struct IDs: Decodable { let ids: [String] }
        guard let id = try JSONDecoder().decode(IDs.self, from: data).ids.first else { throw NestError.invalidResponse }
        return id
    }
    public func begin(id: String, name: String, size: Int64, jobID: UUID) async throws -> URL {
        try validID(id)
        try await storageQuota().requireCapacity(for: size)
        let root = try await folder(role: "storage-v1", name: "CloudNest Storage")
        let archive = try await folder(role: "archives-v1", name: "Archives", parent: root)
        return try await initiate(id: id, name: name, size: size, parent: archive, properties: ["cloudnestJob": jobID.uuidString])
    }
    private func initiate(id: String, name: String, size: Int64, parent: String, properties: [String: String]) async throws -> URL {
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,size,sha256Checksum,trashed")!
        let metadata: [String: Any] = ["id": id, "name": name, "parents": [parent], "mimeType": "application/octet-stream", "appProperties": properties]
        let (_, response) = try await request(url, method: "POST", body: JSONSerialization.data(withJSONObject: metadata), headers: ["Content-Type": "application/json", "X-Upload-Content-Type": "application/octet-stream", "X-Upload-Content-Length": String(size)])
        guard response.statusCode == 200, let location = response.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location) else { throw NestError.http(response.statusCode) }
        try Self.validateGoogleURL(sessionURL)
        return sessionURL
    }
    public static func acknowledgedOffset(range: String?, total: Int64) throws -> Int64 {
        guard let range else { return 0 }
        guard range.hasPrefix("bytes=0-"), let last = Int64(range.dropFirst(8)), last >= 0, last < total else { throw NestError.invalidResponse }
        return last + 1
    }
    private func progress(_ response: HTTPURLResponse, total: Int64) throws -> UploadProgress {
        if response.statusCode == 200 || response.statusCode == 201 { return UploadProgress(offset: total, complete: true) }
        guard response.statusCode == 308 else { throw NestError.http(response.statusCode) }
        return UploadProgress(offset: try Self.acknowledgedOffset(range: response.value(forHTTPHeaderField: "Range"), total: total), complete: false)
    }
    public func status(session: URL, total: Int64) async throws -> UploadProgress {
        let (_, response) = try await request(session, method: "PUT", body: Data(), headers: ["Content-Length": "0", "Content-Range": "bytes */\(total)"])
        return try progress(response, total: total)
    }
    public func send(session: URL, data: Data, offset: Int64, total: Int64) async throws -> UploadProgress {
        let contentRange = total == 0 ? "bytes */0" : "bytes \(offset)-\(offset + Int64(data.count) - 1)/\(total)"
        let (_, response) = try await request(session, method: "PUT", body: data, headers: ["Content-Type": "application/octet-stream", "Content-Length": String(data.count), "Content-Range": contentRange])
        return try progress(response, total: total)
    }
    public func metadata(id: String) async throws -> RemoteFile {
        try validID(id)
        let (data, response) = try await request(endpoint("files/\(id)", ["fields": "id,size,sha256Checksum,trashed"]))
        guard response.statusCode == 200 else { throw NestError.http(response.statusCode) }
        return try JSONDecoder().decode(RemoteFile.self, from: data)
    }
    public func storeManifest(_ manifest: ArchiveManifest) async throws -> String {
        try manifest.validate()
        let root = try await folder(role: "storage-v1", name: "CloudNest Storage")
        let manifests = try await folder(role: "manifests-v1", name: "_manifests", parent: root)
        let data = try manifest.encoded(), id = try await allocateID()
        try await storageQuota().requireCapacity(for: Int64(data.count))
        let sessionURL = try await initiate(id: id, name: manifest.jobID.uuidString + ".json", size: Int64(data.count), parent: manifests, properties: ["cloudnestManifest": manifest.jobID.uuidString])
        let result = try await send(session: sessionURL, data: data, offset: 0, total: Int64(data.count))
        guard result.complete else { throw NestError.verificationFailed }
        return id
    }
    private func existingFolder(role: String, parent: String? = nil) async throws -> String? {
        let query = "trashed = false and mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='cloudnestRole' and value='\(role)' }" + (parent.map { " and '\($0)' in parents" } ?? "")
        let (data, response) = try await request(endpoint("files", ["q": query, "fields": "files(id),nextPageToken,incompleteSearch", "pageSize": "2", "spaces": "drive", "corpora": "user"]))
        guard response.statusCode == 200 else { throw NestError.http(response.statusCode) }
        struct Listing: Decodable { struct Item: Decodable { let id: String }; let files: [Item]; let nextPageToken: String?; let incompleteSearch: Bool? }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        guard listing.files.count < 2, listing.nextPageToken == nil, listing.incompleteSearch != true else { throw NestError.conflict }
        if let id = listing.files.first?.id { try validID(id); return id }
        return nil
    }
    /// Drive supports direct-parent searches. Private marker existence is
    /// checked after this bounded metadata listing, before any content download.
    static func manifestRecoveryQuery(parentID: String) throws -> String {
        guard parentID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw NestError.invalidManifest }
        return "trashed = false and '\(parentID)' in parents"
    }
    /// Rebuild a restore-only catalog from app-owned portable file manifests.
    /// Never scans unrelated Drive files or grants a recovered record local cleanup authority.
    public func recoverCatalog(into catalog: Catalog, maximumManifests: Int = 10_000) async throws -> CatalogRecoveryReport {
        var report = CatalogRecoveryReport()
        guard let root = try await existingFolder(role: "storage-v1"),
              let manifests = try await existingFolder(role: "manifests-v1", parent: root) else { return report }
        var pageToken: String?
        var seenTokens: Set<String> = []
        let maximum = min(100_000, max(1, maximumManifests))
        let staging = catalog.directory.appendingPathComponent("manifest-recovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        repeat {
            try Task.checkCancellation()
            var query = ["q": try Self.manifestRecoveryQuery(parentID: manifests), "fields": "files(id,size,sha256Checksum,trashed,appProperties),nextPageToken,incompleteSearch", "pageSize": "100", "spaces": "drive", "corpora": "user"]
            if let pageToken { query["pageToken"] = pageToken }
            let (data, response) = try await request(endpoint("files", query))
            guard response.statusCode == 200 else { throw NestError.http(response.statusCode) }
            struct Listing: Decodable {
                struct Item: Decodable { let id: String; let size: String?; let sha256Checksum: String?; let trashed: Bool?; let appProperties: [String: String]? }
                let files: [Item]; let nextPageToken: String?; let incompleteSearch: Bool?
            }
            let listing = try JSONDecoder().decode(Listing.self, from: data)
            guard listing.incompleteSearch != true else { throw NestError.invalidResponse }
            for item in listing.files {
                if report.scanned >= maximum { report.truncated = true; return report }
                try Task.checkCancellation(); report.scanned += 1
                guard item.trashed == false, let marker = item.appProperties?["cloudnestManifest"], let jobID = UUID(uuidString: marker),
                      let size = Int64(item.size ?? ""), size >= 0, size <= 131_072,
                      let digest = item.sha256Checksum, digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { report.rejected += 1; continue }
                try validID(item.id)
                let temp = staging.appendingPathComponent(UUID().uuidString + ".json")
                guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NestError.unsafePath("cannot stage recovery manifest") }
                do {
                    let output = try FileHandle(forUpdating: temp); defer { try? output.close() }
                    try await download(id: item.id, into: output, maximumBytes: size)
                    try output.synchronize(); try output.seek(toOffset: 0)
                    let snapshot = try FileSafety.snapshot(output)
                    guard snapshot.identity.size == size, snapshot.sha256 == digest else { throw NestError.verificationFailed }
                    let manifest = try ArchiveManifest.read(from: temp)
                    guard manifest.jobID == jobID else { throw NestError.invalidManifest }
                    let remote = try await metadata(id: manifest.driveFileID)
                    guard remote.trashed == false, Int64(remote.size ?? "") == manifest.size, remote.sha256Checksum == manifest.sha256 else { throw NestError.verificationFailed }
                    let imported = try await catalog.saveRecovered(RecoveredArchive(manifest: manifest, manifestID: item.id))
                    if imported { report.imported += 1 } else { report.existing += 1 }
                } catch NestError.invalidManifest { report.rejected += 1 }
                catch is DecodingError { report.rejected += 1 }
                catch NestError.verificationFailed { report.rejected += 1 }
                catch NestError.http(404) { report.rejected += 1 }
                // Conflicting identities, transport/auth failures and local failures stop visibly.
                try? FileManager.default.removeItem(at: temp)
            }
            pageToken = listing.nextPageToken
            if let pageToken {
                guard pageToken.count <= 4096, seenTokens.insert(pageToken).inserted else { throw NestError.invalidResponse }
            }
        } while pageToken != nil
        return report
    }

    /// Discover only marked root manifests directly inside CloudNest Archives.
    /// Recovered groups carry no local inode identity or cleanup authority.
    public func recoverFolderCatalog(into catalog: Catalog, maximumManifests: Int = 10_000) async throws -> CatalogRecoveryReport {
        var report = CatalogRecoveryReport()
        guard let root = try await existingFolder(role: "storage-v1"),
              let archives = try await existingFolder(role: "archives-v1", parent: root) else { return report }
        let maximum = min(100_000, max(1, maximumManifests))
        var pageToken: String?, seenTokens = Set<String>()
        let staging = catalog.directory.appendingPathComponent("folder-catalog-recovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) } // Private, generated staging only.
        repeat {
            try Task.checkCancellation()
            var query = ["q": try Self.manifestRecoveryQuery(parentID: archives), "fields": "files(id,name,size,sha256Checksum,trashed,appProperties),nextPageToken,incompleteSearch", "pageSize": "100", "spaces": "drive", "corpora": "user"]
            if let pageToken { query["pageToken"] = pageToken }
            let (data, response) = try await request(endpoint("files", query))
            guard response.statusCode == 200 else { throw NestError.http(response.statusCode) }
            struct Listing: Decodable {
                struct Item: Decodable { let id: String; let name: String; let size: String?; let sha256Checksum: String?; let trashed: Bool?; let appProperties: [String: String]? }
                let files: [Item]; let nextPageToken: String?; let incompleteSearch: Bool?
            }
            let listing = try JSONDecoder().decode(Listing.self, from: data)
            guard listing.incompleteSearch != true else { throw NestError.invalidResponse }
            for item in listing.files {
                guard item.name.hasSuffix(".cloudnest-folder.json") else { continue }
                if report.scanned >= maximum { report.truncated = true; return report }
                try Task.checkCancellation(); report.scanned += 1
                guard item.trashed == false, let marker = item.appProperties?["cloudnestJob"], let id = UUID(uuidString: marker),
                      item.name == id.uuidString + ".cloudnest-folder.json", let size = Int64(item.size ?? ""),
                      size > 0, size <= FolderArchiveManifest.maximumBytes,
                      let digest = item.sha256Checksum, digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { report.rejected += 1; continue }
                try validID(item.id)
                let temp = staging.appendingPathComponent(UUID().uuidString + ".json")
                guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NestError.unsafePath("cannot stage folder recovery manifest") }
                do {
                    let output = try FileHandle(forUpdating: temp); defer { try? output.close() }
                    try await download(id: item.id, into: output, maximumBytes: size)
                    try output.synchronize(); try output.seek(toOffset: 0)
                    let snapshot = try FileSafety.snapshot(output)
                    guard snapshot.identity.size == size, snapshot.sha256 == digest else { throw NestError.verificationFailed }
                    let manifest = try FolderArchiveManifest.read(from: temp)
                    guard manifest.id == id else { throw NestError.invalidManifest }
                    let recovered = RecoveredFolderArchive(manifest: manifest, manifestID: item.id)
                    try await FolderArchiveHealthChecker(remote: self).verify(recovered)
                    let imported = try await catalog.saveRecoveredFolder(recovered)
                    if imported { report.imported += 1 } else { report.existing += 1 }
                } catch NestError.invalidManifest { report.rejected += 1 }
                catch is DecodingError { report.rejected += 1 }
                catch NestError.verificationFailed { report.rejected += 1 }
                catch NestError.http(404) { report.rejected += 1 }
                try? FileManager.default.removeItem(at: temp)
            }
            pageToken = listing.nextPageToken
            if let pageToken { guard pageToken.count <= 4096, seenTokens.insert(pageToken).inserted else { throw NestError.invalidResponse } }
        } while pageToken != nil
        return report
    }
    public func download(id: String, into destination: FileHandle, maximumBytes: Int64) async throws {
        try validID(id)
        var request = URLRequest(url: endpoint("files/\(id)", ["alt": "media"]))
        request.setValue("Bearer \(try await oauth.accessToken())", forHTTPHeaderField: "Authorization")
        let cancellation = DownloadCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let delegate = StreamDownload(destination: destination, maximumBytes: maximumBytes) { continuation.resume(with: $0) }
                let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 86_400
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
                let streaming = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
                let task = streaming.dataTask(with: request); cancellation.register(task); task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }
}
