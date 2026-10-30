import Foundation
import Network
import IOKit.ps

public struct TransferPolicy: Codable, Sendable, Equatable {
    public var enabled = false
    public var requireExternalPower = false
    public var allowExpensiveNetworks = false
    public var allowConstrainedNetworks = false
    public var pauseInLowPowerMode = true
    /// Zero means unlimited. This is an average upload pacing limit, not a packet shaper.
    public var uploadBytesPerSecond: Int64 = 0
    public var maximumRetries = 3
    public init() {}
    public func validate() throws {
        guard uploadBytesPerSecond == 0 || (65_536...1_000_000_000).contains(uploadBytesPerSecond),
              (0...5).contains(maximumRetries) else { throw NestError.invalidResponse }
    }
    public func check(_ environment: TransferEnvironment) throws {
        guard enabled else { return }
        guard environment.networkKnown, environment.networkAvailable else { throw TransferPolicyError.networkUnavailable }
        if environment.expensiveNetwork && !allowExpensiveNetworks { throw TransferPolicyError.expensiveNetwork }
        if environment.constrainedNetwork && !allowConstrainedNetworks { throw TransferPolicyError.constrainedNetwork }
        if requireExternalPower && environment.externalPower != true { throw TransferPolicyError.externalPowerRequired }
        if pauseInLowPowerMode && environment.lowPowerMode { throw TransferPolicyError.lowPowerMode }
    }
}

public struct TransferEnvironment: Sendable, Equatable {
    public var networkKnown: Bool
    public var networkAvailable: Bool
    public var expensiveNetwork: Bool
    public var constrainedNetwork: Bool
    public var externalPower: Bool?
    public var lowPowerMode: Bool
    public init(networkKnown: Bool = true, networkAvailable: Bool = true, expensiveNetwork: Bool = false,
                constrainedNetwork: Bool = false, externalPower: Bool? = true, lowPowerMode: Bool = false) {
        self.networkKnown = networkKnown; self.networkAvailable = networkAvailable
        self.expensiveNetwork = expensiveNetwork; self.constrainedNetwork = constrainedNetwork
        self.externalPower = externalPower; self.lowPowerMode = lowPowerMode
    }
}
public enum TransferPolicyError: Error, LocalizedError, Sendable {
    case networkUnavailable, expensiveNetwork, constrainedNetwork, externalPowerRequired, lowPowerMode
    public var errorDescription: String? {
        switch self {
        case .networkUnavailable: "Transfer paused: a usable network could not be established. Resume when connected."
        case .expensiveNetwork: "Transfer paused: this network is marked expensive. Allow metered networks in transfer settings or reconnect."
        case .constrainedNetwork: "Transfer paused: Low Data Mode is active. Change transfer settings or reconnect."
        case .externalPowerRequired: "Transfer paused: external power is required by your settings. Connect power and resume."
        case .lowPowerMode: "Transfer paused: Low Power Mode is active. Resume after changing power mode or transfer settings."
        }
    }
}

/// Uses system notifications for network changes. No timer, rescanning or active network probe.
public final class SystemTransferEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }; self.lock.lock(); self.path = path; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "org.cloudnest.transfer-network", qos: .utility))
    }
    deinit { monitor.cancel() }
    private func currentPath() -> NWPath? { lock.lock(); defer { lock.unlock() }; return path }
    public func current() async throws -> TransferEnvironment {
        var path = currentPath()
        // Await initial notification only while an explicitly requested transfer is starting.
        for _ in 0..<20 where path == nil {
            try await Task.sleep(for: .milliseconds(100)); path = currentPath()
        }
        let source = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let power = source.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        return TransferEnvironment(networkKnown: path != nil, networkAvailable: path?.status == .satisfied,
                                   expensiveNetwork: path?.isExpensive ?? false, constrainedNetwork: path?.isConstrained ?? false,
                                   externalPower: power.map { $0 == kIOPSACPowerValue },
                                   lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

/// Policy wrapper keeps transfer rules independent from catalog integrity and local cleanup.
/// It never retries a non-idempotent manifest creation or blindly resends an accepted upload chunk.
public actor PolicyArchiveRemote: ArchiveRemote {
    private let remote: any ArchiveRemote
    private let policy: TransferPolicy
    private let environment: @Sendable () async throws -> TransferEnvironment
    private let sleep: @Sendable (Duration) async throws -> Void
    public init(remote: any ArchiveRemote, policy: TransferPolicy,
                environment: @escaping @Sendable () async throws -> TransferEnvironment,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        try policy.validate(); self.remote = remote; self.policy = policy; self.environment = environment; self.sleep = sleep
    }
    private func gate() async throws {
        try Task.checkCancellation()
        if policy.enabled { try policy.check(try await environment()) }
    }
    private func retryable(_ error: any Error) -> Bool {
        if let error = error as? NestError, case .http(let status) = error { return [408, 429, 500, 502, 503, 504].contains(status) }
        if let error = error as? DriveServiceError, case .rateLimited = error { return true }
        if let error = error as? URLError { return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code) }
        return false
    }
    private func backoff(_ attempt: Int) async throws { try await sleep(.seconds(min(16, 1 << attempt))) }
    private func idempotent<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try await gate()
            do { return try await operation() }
            catch {
                guard policy.enabled, retryable(error), attempt < policy.maximumRetries else { throw error }
                try await backoff(attempt); attempt += 1
            }
        }
    }
    private func pace(_ bytes: Int) async throws {
        guard policy.enabled, policy.uploadBytesPerSecond > 0 else { return }
        var remaining = Double(bytes) / Double(policy.uploadBytesPerSecond)
        while remaining > 0 {
            let slice = min(remaining, 0.5)
            try await sleep(.nanoseconds(Int64(slice * 1_000_000_000))); remaining -= slice
        }
        try await gate()
    }
    public func allocateID() async throws -> String { try await idempotent { try await self.remote.allocateID() } }
    public func begin(id: String, name: String, size: Int64, jobID: UUID) async throws -> URL {
        try await gate(); return try await remote.begin(id: id, name: name, size: size, jobID: jobID)
    }
    public func status(session: URL, total: Int64) async throws -> UploadProgress { try await idempotent { try await self.remote.status(session: session, total: total) } }
    public func metadata(id: String) async throws -> RemoteFile { try await idempotent { try await self.remote.metadata(id: id) } }
    public func storeManifest(_ manifest: ArchiveManifest) async throws -> String { try await gate(); try await pace(try manifest.encoded().count); return try await remote.storeManifest(manifest) }
    public func download(id: String, into destination: FileHandle, maximumBytes: Int64) async throws {
        try await gate(); try await remote.download(id: id, into: destination, maximumBytes: maximumBytes)
    }
    public func send(session: URL, data: Data, offset: Int64, total: Int64) async throws -> UploadProgress {
        guard offset >= 0, total >= offset, Int64(data.count) <= total - offset else { throw NestError.invalidResponse }
        var attempt = 0, currentOffset = offset
        let end = offset + Int64(data.count)
        while true {
            try await gate()
            let sent = Int(currentOffset - offset)
            let remaining = data.subdata(in: sent..<data.count)
            try await pace(remaining.count)
            do { return try await remote.send(session: session, data: remaining, offset: currentOffset, total: total) }
            catch {
                guard policy.enabled, retryable(error), attempt < policy.maximumRetries else { throw error }
                try await backoff(attempt); attempt += 1
                let authoritative = try await status(session: session, total: total)
                guard authoritative.offset >= currentOffset, authoritative.offset <= total else { throw NestError.invalidResponse }
                if authoritative.complete || authoritative.offset >= end { return authoritative }
                guard authoritative.offset <= end else { throw NestError.invalidResponse }
                currentOffset = authoritative.offset
            }
        }
    }
}
