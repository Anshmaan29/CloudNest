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
        return (data, response)
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
        let sessionURL = try await initiate(id: id, name: manifest.jobID.uuidString + ".json", size: Int64(data.count), parent: manifests, properties: ["cloudnestManifest": manifest.jobID.uuidString])
        let result = try await send(session: sessionURL, data: data, offset: 0, total: Int64(data.count))
        guard result.complete else { throw NestError.verificationFailed }
        return id
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
