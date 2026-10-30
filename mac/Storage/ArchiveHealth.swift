import Foundation
import CryptoKit

public enum ArchiveHealthStatus: String, Codable, Sendable {
    case healthy, missing, mismatch, unavailable, unverified
}

public struct ArchiveHealthReport: Codable, Sendable {
    public let jobID: UUID
    public let status: ArchiveHealthStatus
    public let checkedAt: Date
    public let detail: String
}

/// A metadata audit confirms the file and portable manifest independently.
/// This is not a replacement for a periodic byte-for-byte restore test.
public struct ArchiveHealthChecker: Sendable {
    private let remote: any ArchiveRemote
    public init(remote: any ArchiveRemote) { self.remote = remote }
    public func check(_ job: ArchiveJob) async -> ArchiveHealthReport {
        guard job.state == .verified, let remoteID = job.remoteID, let manifestID = job.manifestID else {
            return report(job.id, .unverified, "This job has not completed file and manifest verification.")
        }
        do {
            try Task.checkCancellation()
            guard try await remote.metadata(id: remoteID).matches(job.snapshot) else {
                return report(job.id, .mismatch, "The archived file metadata no longer matches. Retain local data.")
            }
            let data = try ArchiveManifest(job: job, driveFileID: remoteID).encoded()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let metadata = try await remote.metadata(id: manifestID)
            guard metadata.trashed == false, Int64(metadata.size ?? "") == Int64(data.count), metadata.sha256Checksum == digest else {
                return report(job.id, .mismatch, "The recovery manifest no longer matches. Retain local data.")
            }
            return report(job.id, .healthy, "Drive file and recovery manifest match their recorded sizes and SHA-256 checksums.")
        } catch NestError.http(404) {
            return report(job.id, .missing, "An archived file or recovery manifest is unavailable in Drive. Retain local data.")
        } catch {
            return report(job.id, .unavailable, error is CancellationError ? "Health check cancelled." : "Drive could not be checked. No local data was changed.")
        }
    }
    private func report(_ id: UUID, _ status: ArchiveHealthStatus, _ detail: String) -> ArchiveHealthReport {
        ArchiveHealthReport(jobID: id, status: status, checkedAt: Date(), detail: detail)
    }
}

public struct DriveStorageQuota: Sendable, Equatable {
    /// Google omits limit for unlimited accounts; usage covers all Google services.
    public let limit: Int64?
    public let usage: Int64
    public let usageInDrive: Int64?
    public let usageInDriveTrash: Int64?
    public var available: Int64? { limit.map { max(0, $0 - usage) } }
    public init(limit: Int64?, usage: Int64, usageInDrive: Int64? = nil, usageInDriveTrash: Int64? = nil) throws {
        guard limit.map({ $0 >= 0 }) ?? true, usage >= 0,
              usageInDrive.map({ $0 >= 0 }) ?? true,
              usageInDriveTrash.map({ $0 >= 0 }) ?? true else { throw NestError.invalidResponse }
        self.limit = limit; self.usage = usage; self.usageInDrive = usageInDrive; self.usageInDriveTrash = usageInDriveTrash
    }
    public static func decode(_ data: Data) throws -> DriveStorageQuota {
        struct Response: Decodable {
            struct Values: Decodable { let limit: String?; let usage: String; let usageInDrive: String?; let usageInDriveTrash: String? }
            let storageQuota: Values
        }
        let values = try JSONDecoder().decode(Response.self, from: data).storageQuota
        func parse(_ value: String?) throws -> Int64? {
            guard let value else { return nil }
            guard let parsed = Int64(value), parsed >= 0 else { throw NestError.invalidResponse }
            return parsed
        }
        guard let usage = try parse(values.usage) else { throw NestError.invalidResponse }
        return try DriveStorageQuota(limit: parse(values.limit), usage: usage,
                                     usageInDrive: parse(values.usageInDrive), usageInDriveTrash: parse(values.usageInDriveTrash))
    }
    public func requireCapacity(for bytes: Int64) throws {
        guard bytes >= 0 else { throw NestError.invalidManifest }
        if let available, bytes > available { throw DriveServiceError.quotaExceeded }
    }
}

public enum DriveServiceError: Error, LocalizedError, Sendable {
    case quotaExceeded, rateLimited
    public var errorDescription: String? {
        switch self {
        case .quotaExceeded: "Google storage quota is insufficient. Free cloud space or choose a smaller upload, then retry. Local originals are retained."
        case .rateLimited: "Google Drive is limiting requests. Pause and retry later. Local originals are retained."
        }
    }
}

/// Recovered remote records deliberately carry no local source identity or cleanup permission.
public struct RecoveredArchive: Codable, Sendable, Identifiable {
    public var id: UUID { manifest.jobID }
    public let manifest: ArchiveManifest
    public let manifestID: String
    public let verifiedAt: Date
    public init(manifest: ArchiveManifest, manifestID: String, verifiedAt: Date = Date()) {
        self.manifest = manifest; self.manifestID = manifestID; self.verifiedAt = verifiedAt
    }
}

public struct CatalogRecoveryReport: Sendable {
    public var scanned = 0
    public var imported = 0
    public var existing = 0
    public var rejected = 0
    public var truncated = false
    public init() {}
}
