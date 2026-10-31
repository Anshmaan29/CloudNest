import Foundation
import CryptoKit

public enum BrainArchiveVisibility: String, Codable, Sendable { case `private`, approved }
public enum BrainArchiveKind: String, Codable, Sendable { case file, folder }
public enum BrainArchiveDriveTarget: String, Codable, Sendable { case file, folder, manifest }
public enum BrainArchiveLocalState: String, Codable, Sendable { case original, recovery, removed, unknown }
public enum BrainRestoreAcknowledgement: String, Codable, Sendable { case completed, dismissed }
public enum BrainArchiveError: Error, LocalizedError {
    case invalid(String), unavailable(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return detail
        case .unavailable(let code): return "Brain archive request failed (HTTP \(code)). Local archives are unchanged."
        }
    }
}
public struct BrainArchivePublication: Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let kind: BrainArchiveKind
    public let bytes: Int64
    public let sha256: String?
    public let driveFileId: String
    public let manifestFileId: String
    public let driveTarget: BrainArchiveDriveTarget
    public let fileCount: Int?
    public let checkedAt: String
    public let localState: BrainArchiveLocalState
    private static func fresh(_ id: UUID, _ reportID: UUID, _ status: ArchiveHealthStatus, _ date: Date, now: Date) throws {
        guard id == reportID, status == .healthy, now.timeIntervalSince(date) <= 300, now.timeIntervalSince(date) >= -30 else { throw BrainArchiveError.invalid("Run a fresh successful health check for this archive before publishing its metadata.") }
    }
    private static func timestamp(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    public static func verifiedFile(_ job: ArchiveJob, health: ArchiveHealthReport, now: Date = Date()) throws -> Self {
        try fresh(job.id, health.jobID, health.status, health.checkedAt, now: now)
        guard job.state == .verified, job.folderArchiveID == nil, let remote = job.remoteID, let manifest = job.manifestID else { throw BrainArchiveError.invalid("Select a verified standalone file archive with its recovery manifest.") }
        let state: BrainArchiveLocalState
        switch job.recovery?.stage {
        case .retained: state = .recovery
        case .removed: state = .removed
        default: state = .unknown
        }
        let result = Self(id: job.id, name: job.source.lastPathComponent, kind: .file, bytes: job.snapshot.identity.size, sha256: job.snapshot.sha256, driveFileId: remote, manifestFileId: manifest, driveTarget: .file, fileCount: nil, checkedAt: timestamp(health.checkedAt), localState: state)
        try result.validate(now: now); return result
    }
    public static func verifiedFolder(_ job: FolderArchiveJob, health: FolderArchiveHealthReport, now: Date = Date()) throws -> Self {
        try fresh(job.id, health.jobID, health.status, health.checkedAt, now: now)
        guard job.state == .verified, let manifest = job.manifest, manifest.id == job.id, let remote = job.remoteManifestID,
              manifest.files.count == job.totalFiles else { throw BrainArchiveError.invalid("Load the complete verified folder job and its portable manifest before publishing.") }
        let total = manifest.files.reduce(Int64(0)) { sum, file in let next = sum.addingReportingOverflow(file.manifest.size); return next.overflow ? -1 : next.partialValue }
        guard total >= 0, total == job.totalBytes else { throw BrainArchiveError.invalid("Folder size does not match its verified manifest.") }
        let checksum = try autoreleasepool { SHA256.hash(data: try manifest.encoded()).map { String(format: "%02x", $0) }.joined() }
        let state: BrainArchiveLocalState
        switch job.recovery?.stage {
        case .retained: state = .recovery
        case .removed: state = .removed
        default: state = .unknown
        }
        let result = Self(id: job.id, name: manifest.folderName, kind: .folder, bytes: job.totalBytes, sha256: checksum, driveFileId: remote, manifestFileId: remote, driveTarget: .manifest, fileCount: job.totalFiles, checkedAt: timestamp(health.checkedAt), localState: state)
        try result.validate(now: now); return result
    }
    static func validDriveID(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil }
    static func parseDate(_ value: String) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; if let date = f.date(from: value) { return date }; f.formatOptions = [.withInternetDateTime]; return f.date(from: value) }
    func validate(now: Date = Date()) throws {
        guard !name.isEmpty, name != ".", name != "..", name.count <= 255, name.utf8.count <= 1024,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.illegalCharacters.contains($0) || $0.properties.generalCategory == .format }),
              bytes >= 0, bytes <= 9_007_199_254_740_991, Self.validDriveID(driveFileId), Self.validDriveID(manifestFileId),
              sha256.map({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) ?? true,
              kind == .file ? driveTarget == .file && fileCount == nil : driveTarget != .file && (fileCount.map { $0 >= 0 && $0 <= 10000 } ?? true),
              driveTarget != .manifest || driveFileId == manifestFileId,
              let checked = Self.parseDate(checkedAt), now.timeIntervalSince(checked) <= 300, now.timeIntervalSince(checked) >= -30 else { throw BrainArchiveError.invalid("Archive metadata is invalid or its health check is stale. No paths, contents or credentials may be published.") }
    }
}
public struct BrainPublishedArchive: Codable, Sendable, Identifiable {
    public let id: UUID
    public let project: String
    public let visibility: BrainArchiveVisibility
    public let name: String
    public let kind: BrainArchiveKind
    public let bytes: Int64
    public let sha256: String?
    public let driveFileId: String
    public let manifestFileId: String
    public let driveTarget: BrainArchiveDriveTarget
    public let fileCount: Int?
    public let checkedAt: String
    public let localState: BrainArchiveLocalState
    public let publishedAt: String
    public let driveURL: String
    public let manifestURL: String
    func validateLinks() throws {
        guard BrainArchivePublication.validDriveID(driveFileId), BrainArchivePublication.validDriveID(manifestFileId),
              driveURL == "https://drive.google.com/" + (driveTarget == .folder ? "drive/folders/" + driveFileId : "file/d/" + driveFileId + "/view"),
              manifestURL == "https://drive.google.com/file/d/" + manifestFileId + "/view" else { throw BrainArchiveError.invalid("Brain returned an invalid Drive viewer link.") }
    }
}
public struct BrainPublishedArchivePage: Codable, Sendable { public let archives: [BrainPublishedArchive]; public let cursor: String? }
public struct BrainArchiveRestoreRequest: Codable, Sendable, Identifiable {
    public let id: UUID
    public let archiveId: UUID
    public let archiveName: String?
    public let status: String
    public let createdAt: String
    public let acknowledgedAt: String?
}
private struct ArchiveBrainConnection: Decodable { let origin: String; let token: String }
private final class ArchiveBrainNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
/// Reads only the paired Brain owner credential. It never reads Mac Google tokens.
/// All publication/restore-queue mutations require an explicit owner UI action.
public actor BrainArchiveCatalog {
    private let secrets: any SecretStore
    private let session: URLSession
    public init(secrets: any SecretStore = KeychainStore(), configuration: URLSessionConfiguration? = nil) {
        self.secrets = secrets
        let config = configuration ?? .ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60; config.urlCache = nil
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: ArchiveBrainNoRedirect(), delegateQueue: nil)
    }
    public static func validateOrigin(_ value: String) throws -> URL {
        guard let url = URL(string: value), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port.map({ $0 > 0 && $0 <= 65535 }) ?? true,
              url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) else { throw BrainArchiveError.invalid("Use an HTTPS Brain origin without a path, query or credential. HTTP is allowed only on loopback.") }
        return url
    }
    public func configuredOrigin() async throws -> URL {
        guard let data = try await secrets.read("brain-owner-connection"), data.count <= 2048 else { throw BrainArchiveError.invalid("Connect AI Brain before publishing archive details.") }
        return try Self.validateOrigin(JSONDecoder().decode(ArchiveBrainConnection.self, from: data).origin)
    }
    private func call<T: Decodable & Sendable>(_ path: String, method: String = "GET", payload: Data? = nil, as type: T.Type = T.self) async throws -> T {
        guard let stored = try await secrets.read("brain-owner-connection"), stored.count <= 2048 else { throw BrainArchiveError.invalid("Connect the dedicated Brain owner credential first.") }
        let connection = try JSONDecoder().decode(ArchiveBrainConnection.self, from: stored), origin = try Self.validateOrigin(connection.origin)
        guard connection.token.utf8.count >= 32, connection.token.utf8.count <= 256, connection.token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: "/api/v1" + path, relativeTo: origin)?.absoluteURL,
              url.host == origin.host, url.scheme == origin.scheme, url.port == origin.port else { throw BrainArchiveError.invalid("Invalid Brain connection or archive route.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = payload
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        if payload != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request); defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, [200,201].contains(response.statusCode) else { throw BrainArchiveError.unavailable((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else { throw BrainArchiveError.invalid("Brain did not return JSON.") }
        var data = Data(); data.reserveCapacity(16384)
        for try await byte in bytes {
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            guard data.count < 524288 else { throw BrainArchiveError.invalid("Brain archive response exceeds its 512 KiB budget.") }; data.append(byte)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func validate(_ page: BrainPublishedArchivePage) throws -> BrainPublishedArchivePage { guard page.archives.count <= 100 else { throw BrainArchiveError.invalid("Archive page exceeds its row budget.") }; for row in page.archives { try row.validateLinks() }; return page }
    public func publish(project: String, visibility: BrainArchiveVisibility = .private, archives: [BrainArchivePublication]) async throws -> BrainPublishedArchivePage {
        guard project.utf8.count <= 128, project.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil, (1...20).contains(archives.count), Set(archives.map(\.id)).count == archives.count else { throw BrainArchiveError.invalid("Choose a project and between 1 and 20 distinct verified archives.") }
        for row in archives { try row.validate() }
        struct Payload: Encodable { let project: String; let visibility: BrainArchiveVisibility; let archives: [BrainArchivePublication] }
        let body = try JSONEncoder().encode(Payload(project: project, visibility: visibility, archives: archives))
        guard body.count <= 65536 else { throw BrainArchiveError.invalid("Archive publication exceeds 64 KiB.") }
        let page = try validate(await call("/archives/publish", method: "POST", payload: body))
        guard page.archives.count == archives.count, Set(page.archives.map(\.id)) == Set(archives.map(\.id)), page.archives.allSatisfy({ $0.project == project && $0.visibility == visibility }) else { throw BrainArchiveError.invalid("Brain did not confirm every selected archive publication.") }
        return page
    }
    public func list(query: String = "", project: String = "", cursor: String? = nil, limit: Int = 20) async throws -> BrainPublishedArchivePage {
        guard query.count <= 200, project.count <= 128, (1...100).contains(limit), cursor.map({ UUID(uuidString: $0) != nil }) ?? true else { throw BrainArchiveError.invalid("Invalid archive search or page.") }
        var parts = URLComponents(); parts.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "project", value: project), URLQueryItem(name: "limit", value: String(limit))]; if let cursor { parts.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try validate(await call("/archives?" + (parts.percentEncodedQuery ?? "")))
    }
    public func read(_ id: UUID) async throws -> BrainPublishedArchive {
        struct Response: Decodable, Sendable { let archive: BrainPublishedArchive }
        let response = try await call("/archives/" + id.uuidString.lowercased(), as: Response.self); try response.archive.validateLinks()
        guard response.archive.id == id else { throw BrainArchiveError.invalid("Brain returned a different archive identity.") }; return response.archive
    }
    public func unpublish(_ id: UUID) async throws {
        struct Response: Decodable, Sendable { let unpublished: Bool }
        let response = try await call("/archives/" + id.uuidString.lowercased(), method: "DELETE", as: Response.self)
        guard response.unpublished else { throw BrainArchiveError.invalid("Archive metadata was not unpublished.") }
    }
    public func pendingRestoreRequests() async throws -> [BrainArchiveRestoreRequest] {
        struct Response: Decodable, Sendable { let requests: [BrainArchiveRestoreRequest] }
        let response = try await call("/restore-requests", as: Response.self)
        guard response.requests.count <= 100, response.requests.allSatisfy({ $0.status == "pending" }) else { throw BrainArchiveError.invalid("Invalid restore queue response.") }; return response.requests
    }
    public func requestRestore(archiveId: UUID) async throws -> BrainArchiveRestoreRequest {
        struct Response: Decodable, Sendable { let request: BrainArchiveRestoreRequest }
        let body = try JSONEncoder().encode(["archiveId": archiveId.uuidString.lowercased()]); let response = try await call("/restore-requests", method: "POST", payload: body, as: Response.self)
        guard response.request.archiveId == archiveId, response.request.status == "pending" else { throw BrainArchiveError.invalid("Invalid restore request response.") }; return response.request
    }
    public func acknowledgeRestoreRequest(_ id: UUID, status: BrainRestoreAcknowledgement) async throws -> BrainArchiveRestoreRequest {
        struct Response: Decodable, Sendable { let request: BrainArchiveRestoreRequest }
        let body = try JSONEncoder().encode(["status": status.rawValue]); let response = try await call("/restore-requests/" + id.uuidString.lowercased() + "/ack", method: "POST", payload: body, as: Response.self)
        guard response.request.id == id, response.request.status == status.rawValue else { throw BrainArchiveError.invalid("Invalid restore acknowledgment.") }; return response.request
    }
}
