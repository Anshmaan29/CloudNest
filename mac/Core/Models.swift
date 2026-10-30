import Foundation
import Darwin

public enum NestError: Error, LocalizedError, Sendable {
    case unsafePath(String), sourceChanged, invalidResponse, http(Int), verificationFailed
    case conflict, notConfigured, credentialUnavailable, invalidManifest, busy, database(String)
    public var errorDescription: String? {
        switch self {
        case .unsafePath(let reason): "Path excluded: \(reason)"
        case .sourceChanged: "Source changed. Keep the original and create a new archive job."
        case .invalidResponse: "The service returned an unexpected response."
        case .http(let status): "Service returned HTTP \(status). Retry after checking your connection, authorization and quota."
        case .verificationFailed: "Integrity could not be verified. The local original has been retained."
        case .conflict: "Destination already exists. Choose another location."
        case .notConfigured: "Import a Google Desktop OAuth client configuration first."
        case .credentialUnavailable: "Google Drive is not connected. Sign in again."
        case .invalidManifest: "The archive manifest is invalid or incomplete."
        case .busy: "This transfer is already running."
        case .database(let message): "Catalog error: \(message)"
        }
    }
}

public struct FileIdentity: Codable, Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let changedSeconds: Int64
    public let changedNanos: Int64
}

public struct Snapshot: Codable, Sendable, Equatable {
    public let identity: FileIdentity
    public let sha256: String
}

public struct Candidate: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modified: Date
    public let category: String
}

public struct ScanReport: Sendable {
    public var candidates: [Candidate] = []
    public var excluded = 0
    public var truncated = false
    public var allocatedBytes: Int64 { candidates.reduce(0) { $0 + $1.allocatedBytes } }
    public init() {}
}

public enum TransferState: String, Codable, Sendable {
    case queued, uploading, uploaded, verified
}

public struct LocalRecovery: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case moving, retained, needsReview, removing, removed }
    public var stage: Stage
    public var retainedBytes: Int64
    public var observedFreeSpaceIncrease: Int64
    public var completedAt: Date?
    public init(stage: Stage, retainedBytes: Int64 = 0, observedFreeSpaceIncrease: Int64 = 0, completedAt: Date? = nil) {
        self.stage = stage; self.retainedBytes = retainedBytes
        self.observedFreeSpaceIncrease = observedFreeSpaceIncrease; self.completedAt = completedAt
    }
}

public struct ArchiveJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let source: URL
    public let approvedRoot: URL
    public var snapshot: Snapshot
    public var state: TransferState = .queued
    public var offset: Int64 = 0
    // Session URL is a capability: persisted only in Keychain, never the catalog or manifest.
    public var remoteID: String?
    public var manifestID: String?
    public var lastError: String?
    public var recovery: LocalRecovery?
    public let createdAt: Date
    public init(source: URL, approvedRoot: URL, snapshot: Snapshot) {
        self.id = UUID(); self.source = source; self.approvedRoot = approvedRoot
        self.snapshot = snapshot; self.createdAt = Date()
    }
}

public struct ArchiveManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let jobID: UUID
    public let originalPath: String
    public let fileName: String
    public let size: Int64
    public let sha256: String
    public let driveFileID: String
    public let createdAt: Date
    public init(job: ArchiveJob, driveFileID: String) {
        schemaVersion = 1; jobID = job.id; originalPath = job.source.path
        fileName = job.source.lastPathComponent; size = job.snapshot.identity.size
        sha256 = job.snapshot.sha256; self.driveFileID = driveFileID; createdAt = job.createdAt
    }
    public func validate() throws {
        guard schemaVersion == 1, size >= 0, !driveFileID.isEmpty,
              driveFileID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\0") else { throw NestError.invalidManifest }
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> ArchiveManifest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ArchiveManifest.self, from: data)
        try manifest.validate(); return manifest
    }
    public static func read(from url: URL) throws -> ArchiveManifest {
        let parent = try FileSafety.openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.invalidManifest }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NestError.invalidManifest }
        let data = try file.read(upToCount: 131_073) ?? Data()
        guard data.count <= 131_072 else { throw NestError.invalidManifest }
        return try decode(data)
    }
}

public struct RemoteFile: Codable, Sendable {
    public let id: String
    public let size: String?
    public let sha256Checksum: String?
    public let trashed: Bool?
    public init(id: String, size: String?, sha256Checksum: String?, trashed: Bool? = false) {
        self.id = id; self.size = size; self.sha256Checksum = sha256Checksum; self.trashed = trashed
    }
    public func matches(_ snapshot: Snapshot) -> Bool {
        trashed == false && Int64(size ?? "") == snapshot.identity.size && sha256Checksum == snapshot.sha256
    }
}
