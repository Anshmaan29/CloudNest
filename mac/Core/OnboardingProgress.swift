import Foundation

public enum OnboardingStep: Int, Codable, CaseIterable, Sendable {
    case welcome, googleDrive, folders, safety, brain, assistants, archive, restore
    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .googleDrive: "Google Drive"
        case .folders: "Approved folders"
        case .safety: "Safety & recovery"
        case .brain: "Optional Brain"
        case .assistants: "Your assistants"
        case .archive: "First archive"
        case .restore: "Verified restore"
        }
    }
    public var symbol: String {
        switch self {
        case .welcome: "cloud"
        case .googleDrive: "person.crop.circle.badge.checkmark"
        case .folders: "folder.badge.checkmark"
        case .safety: "checkmark.shield"
        case .brain: "brain"
        case .assistants: "text.bubble"
        case .archive: "arrow.up.doc"
        case .restore: "checkmark.seal"
        }
    }
}

/// A navigation checkpoint, never permission to scan, upload, clean up, or sign in.
/// No Google or Brain credential is stored here.
public struct OnboardingProgress: Codable, Sendable, Equatable {
    public static let defaultsKey = "cloudnest.onboarding.v1"
    public let schemaVersion: Int
    public var step: OnboardingStep = .welcome
    public var furthestStep: OnboardingStep = .welcome
    public var safetyReviewed = false
    public var brainSkipped = false
    public var archiveJobID: UUID?
    public var restoreProof: OnboardingRestoreProof?
    public init() { schemaVersion = 1 }
    public mutating func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
        if next.rawValue > furthestStep.rawValue { furthestStep = next }
    }
    public mutating func visit(_ destination: OnboardingStep) {
        guard destination.rawValue <= furthestStep.rawValue else { return }
        step = destination
    }
    public mutating func selectedArchive(_ id: UUID) {
        if archiveJobID != id { restoreProof = nil }
        archiveJobID = id
    }
    public static func load(from defaults: UserDefaults) throws -> Self {
        guard let data = defaults.data(forKey: defaultsKey) else { return Self() }
        guard data.count <= 16_384 else { throw NestError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.step.rawValue <= value.furthestStep.rawValue else { throw NestError.invalidResponse }
        return value
    }
    public func save(to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

public struct OnboardingRestoreProof: Codable, Sendable, Equatable {
    public let jobID: UUID
    public let restoredURL: URL
    public let sha256: String
    public let bytes: Int64
    public let verifiedAt: Date
    public init(job: ArchiveJob, restoredURL: URL, snapshot: Snapshot) throws {
        guard job.state == .verified, job.remoteID != nil, job.manifestID != nil,
              snapshot.sha256 == job.snapshot.sha256, snapshot.identity.size == job.snapshot.identity.size else { throw NestError.verificationFailed }
        jobID = job.id; self.restoredURL = restoredURL; sha256 = snapshot.sha256
        bytes = snapshot.identity.size; verifiedAt = Date()
    }
    public func matches(_ job: ArchiveJob, snapshot: Snapshot) -> Bool {
        jobID == job.id && job.state == .verified && job.remoteID != nil && job.manifestID != nil &&
        sha256 == job.snapshot.sha256 && bytes == job.snapshot.identity.size &&
        snapshot.sha256 == sha256 && snapshot.identity.size == bytes
    }
}

/// Uses the production catalog and coordinators. It has no cleanup operation.
public actor OnboardingRoundTrip {
    private let catalog: Catalog
    private let coordinator: ArchiveCoordinator
    public private(set) var lastEnqueuedJobID: UUID?
    public init(catalog: Catalog, remote: any ArchiveRemote, secrets: any SecretStore = KeychainStore(), safety: FileSafety = FileSafety()) {
        self.catalog = catalog
        coordinator = ArchiveCoordinator(catalog: catalog, remote: remote, secrets: secrets, safety: safety)
    }
    public func archive(source: URL, approvedRoots: [URL], onEnqueued: @Sendable (ArchiveJob) async -> Void = { _ in }) async throws -> ArchiveJob {
        guard let root = approvedRoots.filter({ FileSafety.contains($0, source) }).max(by: { $0.path.count < $1.path.count }) else {
            throw NestError.unsafePath("choose a file inside an approved folder")
        }
        let job = try await coordinator.enqueue(source: source, approvedRoot: root)
        lastEnqueuedJobID = job.id
        await onEnqueued(job)
        try await coordinator.run(job.id)
        return try await catalog.job(job.id)
    }
    public func resume(_ id: UUID, approvedRoots: [URL]) async throws -> ArchiveJob {
        let job = try await catalog.job(id)
        guard approvedRoots.contains(where: { FileSafety.contains($0, job.source) }) else { throw NestError.unsafePath("approve this archive's source folder before resuming") }
        try await coordinator.run(id)
        return try await catalog.job(id)
    }
    public func restore(_ id: UUID, destination: URL) async throws -> OnboardingRestoreProof {
        let job = try await catalog.job(id)
        guard job.state == .verified, let remoteID = job.remoteID, job.manifestID != nil else { throw NestError.verificationFailed }
        let restored = try await coordinator.restore(manifest: ArchiveManifest(job: job, driveFileID: remoteID), destination: destination)
        let snapshot = try FileSafety().snapshot(restored, root: destination)
        return try OnboardingRestoreProof(job: job, restoredURL: restored, snapshot: snapshot)
    }
    public func validate(_ proof: OnboardingRestoreProof) async throws -> Bool {
        let job = try await catalog.job(proof.jobID)
        let snapshot = try FileSafety().snapshot(proof.restoredURL, root: proof.restoredURL.deletingLastPathComponent())
        return proof.matches(job, snapshot: snapshot)
    }
}
