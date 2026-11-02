import Foundation
import CryptoKit
import Darwin

public enum SmartSweepKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case swiftPMBuild, xcodeBuildProducts, moduleCache, npmCache, pipCache, nodeModules
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .swiftPMBuild: "SwiftPM generated products"
        case .xcodeBuildProducts: "Xcode derived build products"
        case .moduleCache: "Compiler module cache"
        case .npmCache: "npm content cache"
        case .pipCache: "pip download or wheel cache"
        case .nodeModules: "Project node_modules"
        }
    }
    public var regenerationNote: String {
        switch self {
        case .swiftPMBuild: "Run swift build/test again. Select the real .build/<platform>/debug or release folder, never the whole .build folder or dependency checkouts."
        case .xcodeBuildProducts: "Build the project again in Xcode. Only DerivedData/<project>/Build/Products is accepted; source and archives stay outside this selection."
        case .moduleCache: "The compiler will rebuild modules on its next build. The next build may take longer."
        case .npmCache: "npm will download needed packages again. Only an explicitly selected _cacache with content-v2 and index-v5 markers is accepted."
        case .pipCache: "pip will download or rebuild wheels again. Only an explicitly selected pip/http-v2 or pip/wheels cache is accepted."
        case .nodeModules: "Use the project's package manager and reviewed lockfile to reinstall. Local edits, linked dependencies and generated files inside node_modules may be lost after permanent cleanup. CloudNest never runs install scripts."
        }
    }
}
public struct SmartSweepLimits: Sendable {
    public var maximumEntries = 20_000
    public var maximumBytes: Int64 = 10_000_000_000
    public var maximumDepth = 48
    public var scanTimeout: TimeInterval = 30
    public var processTimeout: TimeInterval = 8
    public init() {}
}
public struct SmartSweepProgress: Sendable { public let entries: Int; public let logicalBytes: Int64 }
public struct SmartSweepPreview: Sendable, Identifiable {
    public let id: UUID
    public let root: URL
    public let kind: SmartSweepKind
    public let dependencyEditsAcknowledged: Bool
    public var entryCount: Int { inventory.entries.count }
    public var logicalBytes: Int64 { inventory.logicalBytes }
    public var estimatedAllocatedBytes: Int64 { inventory.allocatedBytes }
    public var sharedInodesExcluded: Int { inventory.sharedInodesExcluded }
    public var symbolicLinkCount: Int { inventory.entries.filter { $0.type == .link }.count }
    fileprivate let inventory: SweepInventory
    fileprivate let parentDevice: Int64
    fileprivate let parentInode: UInt64
}
public struct SmartSweepRecovery: Sendable, Identifiable {
    public let id: UUID
    public let directory: URL
    public let originalRoot: URL
    public let kind: SmartSweepKind
    public let state: String
    public let entryCount: Int
    public let estimatedAllocatedBytes: Int64
    public var payloadURL: URL { directory.appendingPathComponent("payload") }
    public var journalURL: URL { directory.appendingPathComponent("journal.json") }
    fileprivate let journalSHA256: String
}
public struct SmartSweepCleanupResult: Sendable {
    public let removedEntries: Int
    public let estimatedAllocatedBytes: Int64
    /// A volume-wide observation, which may be negative or affected by other activity/APFS snapshots.
    public let observedVolumeFreeBytesDelta: Int64
}
private enum SweepType: String, Codable, Sendable { case directory, file, link }
private struct SweepEntry: Codable, Sendable, Equatable {
    let path: String; let type: SweepType; let identity: FileIdentity
    let mode: UInt16; let flags: UInt32; let links: UInt16; let allocated: Int64; let sha256: String?; let linkTarget: String?
}
private struct SweepInventory: Codable, Sendable, Equatable {
    var entries: [SweepEntry] = []
    var logicalBytes: Int64 = 0; var allocatedBytes: Int64 = 0; var sharedInodesExcluded = 0
}
private struct SweepJournal: Codable {
    var schemaVersion = 1
    let id: UUID; let originalPath: String; let kind: SmartSweepKind; let dependencyEditsAcknowledged: Bool
    let parentDevice: Int64; let parentInode: UInt64
    var state: String; var inventory: SweepInventory
}

/// Explicit local-only staging. No automatic scan, daemon, cloud copy, Trash or recursive unknown deletion.
/// A typed selected-root policy is intentionally separate from ordinary FileSafety.
public struct SmartSweep: Sendable {
    public static let recoveryFolderName = ".cloudnest-sweep-recovery"
    public let protectedRoots: [URL]
    public let limits: SmartSweepLimits
    public init(protectedRoots: [URL] = [], limits: SmartSweepLimits = SmartSweepLimits()) { self.protectedRoots = protectedRoots; self.limits = limits }
    private func validateLimits() throws {
        guard (1...50_000).contains(limits.maximumEntries), limits.maximumBytes > 0, limits.maximumBytes <= 100_000_000_000,
              (1...64).contains(limits.maximumDepth), limits.scanTimeout.isFinite, limits.scanTimeout > 0, limits.scanTimeout <= 300,
              limits.processTimeout.isFinite, limits.processTimeout > 0, limits.processTimeout <= 30 else { throw NestError.unsafePath("invalid Smart Sweep budget") }
    }
    private func policy(_ root: URL, kind: SmartSweepKind, acknowledged: Bool, requireMarker: Bool = true) throws {
        try validateLimits()
        guard root.isFileURL, root.path == root.standardizedFileURL.path, root.pathComponents.count > 3 else { throw NestError.unsafePath("select one fully local generated folder") }
        let path = root.path.lowercased(), parts = root.pathComponents.map { $0.lowercased() }
        let blocked = ["/system", "/library", "/applications", "/private", "/dev", "/usr", "/bin", "/sbin", "/volumes"]
        guard !blocked.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
              !protectedRoots.contains(where: { FileSafety.contains($0, root) || FileSafety.contains(root, $0) }),
              !parts.contains(where: { [".git", ".docker", "cloudstorage", ".trash", Self.recoveryFolderName].contains($0) || $0.hasPrefix("googledrive") || $0.hasPrefix("google drive") || $0.hasPrefix("onedrive") || $0 == "dropbox" || $0.hasSuffix(".app") || $0.hasSuffix(".photoslibrary") }) else { throw NestError.unsafePath("protected, cloud, Docker or package folder") }
        let parent = root.deletingLastPathComponent(), name = root.lastPathComponent
        var accepted = false, permitsLibrary = false
        switch kind {
        case .swiftPMBuild:
            let package = parts.lastIndex(of: ".build")
            if ["debug", "release"].contains(name), let package, parts.count - package <= 3 {
                var packageRoot = root
                for _ in package..<parts.count { packageRoot.deleteLastPathComponent() }
                accepted = try SweepFS.marker(packageRoot.appendingPathComponent("Package.swift"))
            }
        case .xcodeBuildProducts:
            let derived = path.contains("/library/developer/xcode/deriveddata/")
            permitsLibrary = derived
            let project = parent.deletingLastPathComponent()
            let marker = try SweepFS.marker(project.appendingPathComponent("info.plist"))
            accepted = name == "Products" && parent.lastPathComponent == "Build" && derived && marker
        case .moduleCache:
            permitsLibrary = path.hasSuffix("/library/developer/xcode/deriveddata/modulecache.noindex")
            accepted = permitsLibrary && name == "ModuleCache.noindex"
            if name == "ModuleCache", let build = parts.lastIndex(of: ".build") {
                var packageRoot = root
                for _ in build..<parts.count { packageRoot.deleteLastPathComponent() }
                accepted = try SweepFS.marker(packageRoot.appendingPathComponent("Package.swift"))
            }
        case .npmCache:
            permitsLibrary = path.contains("/library/caches/")
            let content = !requireMarker || SweepFS.directoryMarker(root.appendingPathComponent("content-v2"))
            let index = !requireMarker || SweepFS.directoryMarker(root.appendingPathComponent("index-v5"))
            accepted = name == "_cacache" && content && index
        case .pipCache:
            permitsLibrary = path.contains("/library/caches/pip/")
            accepted = ["http-v2", "wheels"].contains(name) && parent.lastPathComponent == "pip"
        case .nodeModules:
            guard acknowledged else { throw NestError.unsafePath("affirm that local dependency edits may be lost before reviewing node_modules") }
            let package = try SweepFS.marker(parent.appendingPathComponent("package.json"))
            let lock = try ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"].contains { try SweepFS.marker(parent.appendingPathComponent($0)) }
            accepted = name == "node_modules" && package && lock
        }
        guard accepted, !parts.contains("library") || permitsLibrary else { throw NestError.unsafePath("selected folder does not match this known regenerable root and its rebuild markers") }
        // Every existing ancestor is walked without following links. No whole Library exception exists.
        let parentFD = try SweepFS.directory(parent); defer { close(parentFD) }
        try SweepFS.owned(parentFD)
        if requireMarker { let fd = try SweepFS.directory(root); defer { close(fd) }; try SweepFS.owned(fd) }
    }
    public func preview(root: URL, kind: SmartSweepKind, dependencyEditsAcknowledged: Bool = false,
                        onProgress: @Sendable (SmartSweepProgress) -> Void = { _ in }) async throws -> SmartSweepPreview {
        try policy(root, kind: kind, acknowledged: dependencyEditsAcknowledged)
        try processGuard(root: root, project: Self.projectAnchor(root, kind: kind))
        let inventory = try scan(root, kind: kind, onProgress: onProgress)
        let parent = try SweepFS.directory(root.deletingLastPathComponent()); defer { close(parent) }
        let identity = try SweepFS.identity(parent)
        return SmartSweepPreview(id: UUID(), root: root, kind: kind, dependencyEditsAcknowledged: dependencyEditsAcknowledged, inventory: inventory, parentDevice: identity.device, parentInode: identity.inode)
    }
    public func stage(approved preview: SmartSweepPreview) async throws -> SmartSweepRecovery {
        try policy(preview.root, kind: preview.kind, acknowledged: preview.dependencyEditsAcknowledged)
        try processGuard(root: preview.root, project: Self.projectAnchor(preview.root, kind: preview.kind))
        guard try scan(preview.root, kind: preview.kind) == preview.inventory else { throw NestError.sourceChanged }
        let parent = try SweepFS.directory(preview.root.deletingLastPathComponent()); defer { close(parent) }
        let identity = try SweepFS.identity(parent)
        guard identity.device == preview.parentDevice, identity.inode == preview.parentInode else { throw NestError.sourceChanged }
        let catalog = try SweepFS.catalog(parent: parent, create: true); defer { close(catalog) }
        let catalogURL = preview.root.deletingLastPathComponent().appendingPathComponent(Self.recoveryFolderName)
        let lease = try OperationLease.acquire(catalogDirectory: catalogURL, jobID: preview.id); defer { withExtendedLifetime(lease) {} }
        let name = preview.id.uuidString
        guard mkdirat(catalog, name, 0o700) == 0 else { throw NestError.conflict }
        let job = try SweepFS.childDirectory(catalog, name); defer { close(job) }
        var journal = SweepJournal(id: preview.id, originalPath: preview.root.path, kind: preview.kind, dependencyEditsAcknowledged: preview.dependencyEditsAcknowledged,
                                   parentDevice: preview.parentDevice, parentInode: preview.parentInode, state: "prepared", inventory: preview.inventory)
        try SweepFS.writeJournal(journal, job: job)
        try Task.checkCancellation()
        let named = try SweepFS.statAt(parent, preview.root.lastPathComponent)
        guard FileSafety.identity(named) == preview.inventory.entries[0].identity else { throw NestError.sourceChanged }
        guard renameatx_np(parent, preview.root.lastPathComponent, job, "payload", UInt32(RENAME_EXCL)) == 0 else { throw NestError.conflict }
        guard fsync(parent) == 0, fsync(job) == 0, fsync(catalog) == 0 else { throw NestError.unsafePath("staging synchronization uncertain; retain the private recovery job") }
        let directory = catalogURL.appendingPathComponent(name)
        do {
            let moved = try scan(directory.appendingPathComponent("payload"), kind: preview.kind)
            guard Self.equalAcrossRename(preview.inventory, moved) else { throw NestError.sourceChanged }
            journal.inventory = moved; journal.state = "staged"; try SweepFS.writeJournal(journal, job: job)
        } catch {
            journal.state = "uncertain"; try? SweepFS.writeJournal(journal, job: job)
            throw NestError.unsafePath("folder is staged but verification was interrupted or changed; retain the recovery job and explicitly put it back")
        }
        return try Self.readRecovery(directory)
    }
    /// `under` is the explicitly selected original parent containing the hidden recovery catalog.
    public static func recoveries(under parent: URL) throws -> [SmartSweepRecovery] {
        let fd = try SweepFS.directory(parent); defer { close(fd) }
        var info = stat()
        if fstatat(fd, recoveryFolderName, &info, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return [] }; throw NestError.invalidResponse }
        let catalog = try SweepFS.catalog(parent: fd, create: false); defer { close(catalog) }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        return try SweepFS.names(catalog, maximum: 1000).filter { !$0.hasPrefix(".operation-") }.map { name in
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("recovery catalog exceeds its read budget; retain the jobs") }
            guard UUID(uuidString: name) != nil else { throw NestError.unsafePath("unknown recovery catalog member; retain it") }
            return try readRecovery(parent.appendingPathComponent(recoveryFolderName).appendingPathComponent(name))
        }
    }
    public func putBack(approved recovery: SmartSweepRecovery) async throws {
        try validateLimits()
        let (journal, job, parent, lease) = try openRecovery(recovery)
        defer { close(job); close(parent); withExtendedLifetime(lease) {} }
        guard ["prepared", "staged", "uncertain", "putBackStarted"].contains(journal.state) else { throw NestError.unsafePath("this recovery is incomplete or already cleaned; retain its journal for manual inspection") }
        try policy(recovery.originalRoot, kind: journal.kind, acknowledged: journal.dependencyEditsAcknowledged, requireMarker: false)
        let payload = try SweepFS.childDirectory(job, "payload"); defer { close(payload) }
        let actual = try SweepFS.identity(payload), expected = journal.inventory.entries[0].identity
        guard actual.device == expected.device, actual.inode == expected.inode else { throw NestError.sourceChanged }
        try processGuard(root: recovery.payloadURL, project: nil)
        var updated = journal; updated.state = "putBackStarted"; try SweepFS.writeJournal(updated, job: job)
        try Task.checkCancellation()
        guard renameatx_np(job, "payload", parent, recovery.originalRoot.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw NestError.conflict }
        guard fsync(parent) == 0, fsync(job) == 0 else { throw NestError.unsafePath("put-back synchronization uncertain; retain the journal") }
        updated.state = "restored"; try SweepFS.writeJournal(updated, job: job)
    }
    public func purge(approved recovery: SmartSweepRecovery, permanentlyDeleteAcknowledged: Bool = false,
                      onProgress: @Sendable (SmartSweepProgress) -> Void = { _ in }) async throws -> SmartSweepCleanupResult {
        guard permanentlyDeleteAcknowledged else { throw NestError.unsafePath("permanent cleanup requires a separate affirmative approval") }
        try validateLimits()
        var (journal, job, parent, lease) = try openRecovery(recovery)
        defer { close(job); close(parent); withExtendedLifetime(lease) {} }
        guard journal.inventory.sharedInodesExcluded == 0 else { throw NestError.unsafePath("hard-linked content is retained; put this selection back instead of claiming reclaimed space") }
        guard journal.state == "staged" else { throw NestError.unsafePath("only a fully staged, freshly reviewed job can be cleaned; interrupted cleanup never resumes automatically") }
        try policy(recovery.originalRoot, kind: journal.kind, acknowledged: journal.dependencyEditsAcknowledged, requireMarker: false)
        try processGuard(root: recovery.payloadURL, project: Self.projectAnchor(recovery.originalRoot, kind: journal.kind))
        guard try scan(recovery.payloadURL, kind: journal.kind) == journal.inventory else { throw NestError.sourceChanged }
        let beforeFree = try SweepFS.freeBytes(parent)
        journal.state = "purgeStarted"; try SweepFS.writeJournal(journal, job: job)
        let payload = try SweepFS.childDirectory(job, "payload"); defer { close(payload) }
        var removed = 0
        let purgeDeadline = ProcessInfo.processInfo.systemUptime + limits.scanTimeout
        var expectedDirectories = Dictionary(uniqueKeysWithValues: journal.inventory.entries.filter { $0.type == .directory }.map { ($0.path, $0.identity) })
        // Delete only reviewed names, deepest first. Unknown additions are never traversed or deleted.
        for entry in journal.inventory.entries.sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) where !entry.path.isEmpty {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < purgeDeadline else { throw NestError.unsafePath("cleanup time budget exceeded; remaining staged content is retained") }
            let components = try SweepFS.components(entry.path)
            var directory = dup(payload); guard directory >= 0 else { throw NestError.invalidResponse }
            do {
                for component in components.dropLast() { let next = try SweepFS.childDirectory(directory, component); close(directory); directory = next }
                let parentPath = components.dropLast().joined(separator: "/")
                guard try SweepFS.identity(directory) == expectedDirectories[parentPath] else { throw NestError.sourceChanged }
                let name = components.last!, info = try SweepFS.statAt(directory, name)
                guard Self.matchesForRemoval(entry, info) else { throw NestError.sourceChanged }
                if entry.type == .directory {
                    let child = try SweepFS.childDirectory(directory, name); defer { close(child) }
                    guard try SweepFS.names(child, maximum: limits.maximumEntries).isEmpty else { throw NestError.sourceChanged }
                } else if entry.type == .file {
                    let fd = try SweepFS.file(directory, name); defer { close(fd) }
                    guard try SweepFS.hash(fd, maximum: limits.maximumBytes, deadline: purgeDeadline) == entry.sha256,
                          try SweepFS.identity(fd) == FileSafety.identity(info) else { throw NestError.sourceChanged }
                } else { guard try SweepFS.link(directory, name) == entry.linkTarget else { throw NestError.sourceChanged } }
                let final = try SweepFS.statAt(directory, name)
                guard Self.matchesForRemoval(entry, final), unlinkat(directory, name, entry.type == .directory ? AT_REMOVEDIR : 0) == 0 else { throw NestError.sourceChanged }
                expectedDirectories[parentPath] = try SweepFS.identity(directory)
                close(directory)
            } catch { close(directory); throw error }
            removed += 1; onProgress(SmartSweepProgress(entries: removed, logicalBytes: 0))
        }
        guard try SweepFS.names(payload, maximum: limits.maximumEntries).isEmpty,
              (try SweepFS.identity(payload)).inode == journal.inventory.entries[0].identity.inode,
              unlinkat(job, "payload", AT_REMOVEDIR) == 0, fsync(job) == 0 else { throw NestError.sourceChanged }
        journal.state = "purged"; try SweepFS.writeJournal(journal, job: job)
        let afterFree = try SweepFS.freeBytes(parent)
        return SmartSweepCleanupResult(removedEntries: removed + 1, estimatedAllocatedBytes: journal.inventory.allocatedBytes, observedVolumeFreeBytesDelta: afterFree - beforeFree)
    }
    private static func matchesForRemoval(_ entry: SweepEntry, _ info: stat) -> Bool {
        let identity = FileSafety.identity(info)
        // Removing children changes directory timestamps/size. Directory inode, owner, mode and flags remain guarded.
        return info.st_uid == getuid() && info.st_mode == entry.mode && info.st_flags == entry.flags &&
            (entry.type == .directory ? identity.device == entry.identity.device && identity.inode == entry.identity.inode : identity == entry.identity)
    }
    private func openRecovery(_ recovery: SmartSweepRecovery) throws -> (SweepJournal, Int32, Int32, OperationLease) {
        let current = try Self.readRecovery(recovery.directory)
        guard current.journalSHA256 == recovery.journalSHA256, current.id == recovery.id else { throw NestError.sourceChanged }
        let catalog = recovery.directory.deletingLastPathComponent()
        let lease = try OperationLease.acquire(catalogDirectory: catalog, jobID: recovery.id)
        let parent = try SweepFS.directory(recovery.originalRoot.deletingLastPathComponent())
        do {
            let identity = try SweepFS.identity(parent)
            let job = try SweepFS.directory(recovery.directory)
            do {
                let journalData = try SweepFS.journalBytes(job)
                guard SweepFS.digest(journalData) == recovery.journalSHA256 else { throw NestError.sourceChanged }
                let journal = try JSONDecoder().decode(SweepJournal.self, from: journalData)
                guard journal.parentDevice == identity.device, journal.parentInode == identity.inode,
                      journal.originalPath == recovery.originalRoot.path, journal.id == recovery.id else { throw NestError.sourceChanged }
                return (journal, job, parent, lease)
            } catch { close(job); throw error }
        } catch { close(parent); throw error }
    }
    private static func readRecovery(_ directory: URL) throws -> SmartSweepRecovery {
        guard directory.deletingLastPathComponent().lastPathComponent == recoveryFolderName, let id = UUID(uuidString: directory.lastPathComponent) else { throw NestError.invalidManifest }
        let fd = try SweepFS.directory(directory); defer { close(fd) }; try SweepFS.owned(fd, privateOnly: true)
        let data = try SweepFS.journalBytes(fd), journal = try JSONDecoder().decode(SweepJournal.self, from: data)
        guard journal.schemaVersion == 1, journal.id == id, !journal.inventory.entries.isEmpty, journal.inventory.entries.count <= 50_000,
              journal.inventory.entries[0].path.isEmpty, journal.inventory.entries[0].type == .directory,
              URL(fileURLWithPath: journal.originalPath).deletingLastPathComponent().path == directory.deletingLastPathComponent().deletingLastPathComponent().path,
              ["prepared", "staged", "uncertain", "purgeStarted", "purged", "putBackStarted", "restored"].contains(journal.state) else { throw NestError.invalidManifest }
        for entry in journal.inventory.entries where !entry.path.isEmpty { _ = try SweepFS.components(entry.path) }
        return SmartSweepRecovery(id: id, directory: directory, originalRoot: URL(fileURLWithPath: journal.originalPath), kind: journal.kind, state: journal.state,
                                  entryCount: journal.inventory.entries.count, estimatedAllocatedBytes: journal.inventory.allocatedBytes, journalSHA256: SweepFS.digest(data))
    }
    private static func equalAcrossRename(_ lhs: SweepInventory, _ rhs: SweepInventory) -> Bool {
        guard lhs.entries.count == rhs.entries.count, lhs.logicalBytes == rhs.logicalBytes, lhs.allocatedBytes == rhs.allocatedBytes,
              lhs.sharedInodesExcluded == rhs.sharedInodesExcluded else { return false }
        return zip(lhs.entries, rhs.entries).allSatisfy { a, b in
            if !a.path.isEmpty { return a == b }
            return a.identity.device == b.identity.device && a.identity.inode == b.identity.inode && a.identity.modifiedSeconds == b.identity.modifiedSeconds && a.identity.modifiedNanos == b.identity.modifiedNanos && a.mode == b.mode && a.flags == b.flags
        }
    }
    private func scan(_ root: URL, kind: SmartSweepKind, onProgress: @Sendable (SmartSweepProgress) -> Void = { _ in }) throws -> SweepInventory {
        try validateLimits()
        let fd = try SweepFS.directory(root); defer { close(fd) }
        let device = try SweepFS.identity(fd).device, deadline = ProcessInfo.processInfo.systemUptime + limits.scanTimeout
        var inventory = SweepInventory(), seen = Set<String>(), shared = Set<String>(), nextProgress: TimeInterval = 0
        func walk(_ directory: Int32, relative: String, depth: Int) throws {
            try Task.checkCancellation(); guard depth <= limits.maximumDepth, ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("sweep depth/time budget exceeded; nothing is approved") }
            try SweepFS.owned(directory)
            let before = try SweepFS.identity(directory), names = try SweepFS.names(directory, maximum: limits.maximumEntries)
            guard !names.contains(where: { [".git", "PG_VERSION", "WiredTiger", "ibdata1", "data.mdb"].contains($0) }) else { throw NestError.unsafePath("repository metadata or database storage inside selection") }
            for name in names {
                try Task.checkCancellation()
                guard inventory.entries.count < limits.maximumEntries, ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("sweep entry/time budget exceeded; nothing is approved") }
                let relativePath = relative.isEmpty ? name : relative + "/" + name
                _ = try SweepFS.components(relativePath)
                let info = try SweepFS.statAt(directory, name), identity = FileSafety.identity(info)
                guard identity.device == device, info.st_uid == getuid(), (info.st_mode & S_IFMT == S_IFLNK || info.st_mode & 0o022 == 0),
                      info.st_flags & UInt32(SF_DATALESS | UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw NestError.unsafePath("shared, immutable, mounted or cloud-placeholder content") }
                var type: SweepType, hash: String?, target: String?
                switch info.st_mode & S_IFMT {
                case S_IFDIR: type = .directory
                case S_IFREG:
                    type = .file
                    let lower = name.lowercased(), ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                    guard !["db", "sqlite", "sqlite3", "realm", "mdb", "lmdb", "wal", "shm", "raw", "qcow2", "vmdk", "vhdx"].contains(ext), !lower.hasSuffix("-wal"), !lower.hasSuffix("-shm") else { throw NestError.unsafePath("database or virtual disk content is never swept") }
                    let file = try SweepFS.file(directory, name); defer { close(file) }
                    var magic = [UInt8](repeating: 0, count: 16)
                    let count = read(file, &magic, magic.count)
                    guard count >= 0, Data(magic.prefix(count)) != Data("SQLite format 3\0".utf8), lseek(file, 0, SEEK_SET) == 0 else { throw NestError.unsafePath("database content or unreadable file") }
                    hash = try SweepFS.hash(file, maximum: limits.maximumBytes - inventory.logicalBytes, deadline: deadline)
                    guard try SweepFS.identity(file) == identity else { throw NestError.sourceChanged }
                    let key = "\(identity.device):\(identity.inode)"
                    if seen.insert(key).inserted {
                        guard identity.size >= 0, inventory.logicalBytes <= limits.maximumBytes - identity.size else { throw NestError.unsafePath("sweep byte budget exceeded") }
                        inventory.logicalBytes += identity.size
                        if info.st_nlink == 1 { let blocks = Int64(info.st_blocks).multipliedReportingOverflow(by: 512); guard !blocks.overflow, blocks.partialValue >= 0, inventory.allocatedBytes <= Int64.max - blocks.partialValue else { throw NestError.invalidResponse }; inventory.allocatedBytes += blocks.partialValue }
                        else { shared.insert(key) }
                    }
                case S_IFLNK:
                    guard kind == .nodeModules else { throw NestError.unsafePath("symbolic links are supported only inside acknowledged node_modules") }
                    type = .link; target = try SweepFS.link(directory, name)
                default: throw NestError.unsafePath("socket, device or special file inside sweep root")
                }
                inventory.entries.append(SweepEntry(path: relativePath, type: type, identity: identity, mode: info.st_mode, flags: info.st_flags, links: info.st_nlink, allocated: Int64(info.st_blocks) * 512, sha256: hash, linkTarget: target))
                if type == .directory { let child = try SweepFS.childDirectory(directory, name); defer { close(child) }; try walk(child, relative: relativePath, depth: depth + 1) }
                guard FileSafety.identity(try SweepFS.statAt(directory, name)) == identity else { throw NestError.sourceChanged }
                if ProcessInfo.processInfo.systemUptime >= nextProgress { onProgress(SmartSweepProgress(entries: inventory.entries.count, logicalBytes: inventory.logicalBytes)); nextProgress = ProcessInfo.processInfo.systemUptime + 0.2 }
            }
            guard try SweepFS.identity(directory) == before else { throw NestError.sourceChanged }
        }
        let rootInfo = try SweepFS.statFD(fd); try SweepFS.owned(fd)
        guard rootInfo.st_flags & UInt32(SF_DATALESS | UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw NestError.unsafePath("immutable or cloud-placeholder root") }
        inventory.entries.append(SweepEntry(path: "", type: .directory, identity: FileSafety.identity(rootInfo), mode: rootInfo.st_mode, flags: rootInfo.st_flags, links: rootInfo.st_nlink, allocated: 0, sha256: nil, linkTarget: nil))
        try walk(fd, relative: "", depth: 0); inventory.sharedInodesExcluded = shared.count
        return inventory
    }
    private static func projectAnchor(_ root: URL, kind: SmartSweepKind) -> URL? {
        if kind == .nodeModules { return root.deletingLastPathComponent() }
        if kind == .swiftPMBuild || kind == .moduleCache, let index = root.pathComponents.lastIndex(of: ".build") {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(root.pathComponents.prefix(index))))
        }
        return nil
    }
    private func processGuard(root: URL, project: URL?) throws {
        let output = try SweepFS.process(["-t", "+D", root.path], timeout: limits.processTimeout)
        let pids = output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        guard !pids.contains(where: { $0 != getpid() }) else { throw NestError.unsafePath("selected content is open in another process; close it before sweeping") }
        if let project {
            let text = try SweepFS.process(["-a", "-u", String(getuid()), "-d", "cwd", "-Fpcn"], timeout: limits.processTimeout)
            var pid: Int32?, command = ""
            for line in text.split(separator: "\n") {
                if line.first == "p" { pid = Int32(line.dropFirst()) }
                if line.first == "c" { command = String(line.dropFirst()).lowercased() }
                if line.first == "n", pid != getpid(), ["swift", "xcodebuild", "clang", "make", "ninja", "npm", "node", "yarn", "pnpm", "bun", "pip", "python"].contains(where: { command.hasPrefix($0) }) {
                    let cwd = URL(fileURLWithPath: String(line.dropFirst()))
                    guard !FileSafety.contains(project, cwd) else { throw NestError.unsafePath("a build or dependency process is active in the selected project") }
                }
            }
        }
    }
}

private enum SweepFS {
    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), path.utf8.count <= 4096, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) && !$0.contains("\n") }) else { throw NestError.invalidManifest }
        return parts
    }
    static func directory(_ url: URL) throws -> Int32 {
        let fd = try FileSafety.openDirectory(url)
        do { let info = try statFD(fd); var volume = statfs(); guard info.st_mode & S_IFMT == S_IFDIR, info.st_flags & UInt32(SF_DATALESS) == 0, fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw NestError.unsafePath("directory is not fully local") }; return fd } catch { close(fd); throw error }
    }
    static func childDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
        guard !name.contains("/"), name != ".", name != ".." else { throw NestError.invalidManifest }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NestError.sourceChanged }; return fd
    }
    static func statFD(_ fd: Int32) throws -> stat { var info = stat(); guard fstat(fd, &info) == 0 else { throw NestError.invalidResponse }; return info }
    static func identity(_ fd: Int32) throws -> FileIdentity { FileSafety.identity(try statFD(fd)) }
    static func statAt(_ fd: Int32, _ name: String) throws -> stat { var info = stat(); guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NestError.sourceChanged }; return info }
    static func owned(_ fd: Int32, privateOnly: Bool = false) throws {
        let info = try statFD(fd)
        guard info.st_uid == getuid(), info.st_mode & (privateOnly ? 0o077 : 0o022) == 0 else { throw NestError.unsafePath("folder must be owned and unshared") }
        guard let security = filesec_init() else { throw NestError.invalidResponse }; defer { filesec_free(security) }
        var secured = stat(), acl: Int32 = 0
        guard fstatx_np(fd, &secured, security) == 0, secured.st_ino == info.st_ino, secured.st_dev == info.st_dev,
              filesec_query_property(security, FILESEC_ACL, &acl) == 0, acl == 0 else { throw NestError.unsafePath("additional folder access permissions are unsupported") }
    }
    static func marker(_ url: URL) throws -> Bool {
        let parent = try directory(url.deletingLastPathComponent()); defer { close(parent) }
        var info = stat(); if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return false }; throw NestError.invalidResponse }
        return info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_size > 0 && info.st_size <= 1_048_576 && info.st_mode & 0o022 == 0
    }
    static func directoryMarker(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() }
    static func catalog(parent: Int32, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, SmartSweep.recoveryFolderName, 0o700) != 0, errno != EEXIST { throw NestError.invalidResponse }
        let fd = try childDirectory(parent, SmartSweep.recoveryFolderName)
        do { try owned(fd, privateOnly: true); return fd } catch { close(fd); throw error }
    }
    static func names(_ fd: Int32, maximum: Int) throws -> [String] {
        let copy = dup(fd); guard copy >= 0 else { throw NestError.invalidResponse }
        guard let stream = fdopendir(copy) else { close(copy); throw NestError.invalidResponse }; defer { closedir(stream) }; rewinddir(stream)
        var names: [String] = []
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw NestError.invalidResponse }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            guard names.count < maximum else { throw NestError.unsafePath("directory exceeds sweep entry budget") }; names.append(name)
        }
        return names.sorted()
    }
    static func file(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NestError.sourceChanged }
        do { let info = try statFD(fd); try owned(fd); guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o022 == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw NestError.sourceChanged }; return fd } catch { close(fd); throw error }
    }
    static func link(_ parent: Int32, _ name: String) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4097)
        let count = readlinkat(parent, name, &bytes, bytes.count)
        guard count > 0, count < bytes.count, let value = String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else { throw NestError.invalidManifest }; return value
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ fd: Int32, maximum: Int64, deadline: TimeInterval) throws -> String {
        let before = try identity(fd); guard before.size >= 0, before.size <= maximum, lseek(fd, 0, SEEK_SET) == 0 else { throw NestError.unsafePath("sweep byte budget exceeded") }
        var hash = SHA256(), bytes: Int64 = 0
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        while let data = try autoreleasepool(invoking: { try handle.read(upToCount: 1_048_576) }), !data.isEmpty {
            try Task.checkCancellation(); guard ProcessInfo.processInfo.systemUptime < deadline, bytes <= maximum - Int64(data.count) else { throw NestError.unsafePath("sweep byte/time budget exceeded") }; hash.update(data: data); bytes += Int64(data.count)
        }
        guard try identity(fd) == before, bytes == before.size else { throw NestError.sourceChanged }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func write(_ data: Data, _ fd: Int32) throws {
        try data.withUnsafeBytes { raw in var offset = 0; while offset < raw.count { let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw NestError.invalidResponse }; offset += count } }
    }
    static func writeJournal(_ journal: SweepJournal, job: Int32) throws {
        let name = ".journal-" + UUID().uuidString
        let fd = openat(job, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NestError.invalidResponse }; defer { close(fd) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let data = try encoder.encode(journal)
        guard data.count <= 32 * 1024 * 1024 else { throw NestError.unsafePath("sweep journal exceeds budget") }
        try write(data, fd)
        guard fsync(fd) == 0, renameat(job, name, job, "journal.json") == 0, fsync(job) == 0 else { throw NestError.unsafePath("sweep journal could not be durably saved") }
    }
    static func journalBytes(_ job: Int32) throws -> Data {
        let fd = try file(job, "journal.json"); defer { close(fd) }
        let before = try statFD(fd); guard before.st_nlink == 1, before.st_mode & 0o077 == 0, before.st_size > 0, before.st_size <= 32 * 1024 * 1024 else { throw NestError.invalidManifest }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
        guard data.count == before.st_size, try identity(fd) == FileSafety.identity(before) else { throw NestError.sourceChanged }; return data
    }
    static func readJournal(_ job: Int32) throws -> SweepJournal { try JSONDecoder().decode(SweepJournal.self, from: journalBytes(job)) }
    static func freeBytes(_ fd: Int32) throws -> Int64 { var info = statfs(); guard fstatfs(fd, &info) == 0 else { throw NestError.invalidResponse }; let result = Int64(clamping: info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize)); guard !result.overflow else { throw NestError.invalidResponse }; return result.partialValue }
    static func process(_ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process(), output = Pipe(), errors = Pipe(), ended = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); process.arguments = arguments
        process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        try process.run(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let out = output.fileHandleForReading.fileDescriptor, err = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(out, F_SETFL, fcntl(out, F_GETFL) | O_NONBLOCK); _ = fcntl(err, F_SETFL, fcntl(err, F_GETFL) | O_NONBLOCK)
        defer { try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data(), diagnostics = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        do {
            while process.isRunning {
                try Task.checkCancellation(); guard ProcessInfo.processInfo.systemUptime < deadline else { throw NestError.unsafePath("process-use check timed out; keep the selected data") }
                for (fd, errorPipe) in [(out, false), (err, true)] {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 { if errorPipe { diagnostics.append(contentsOf: buffer.prefix(count)) } else { data.append(contentsOf: buffer.prefix(count)) } }
                }
                guard data.count + diagnostics.count <= 1_048_576 else { throw NestError.unsafePath("process-use check exceeded its output budget") }
                _ = ended.wait(timeout: .now() + .milliseconds(10))
            }
            process.waitUntilExit()
            for (fd, errorPipe) in [(out, false), (err, true)] {
                while true { let count = read(fd, &buffer, buffer.count); if count <= 0 { break }; if errorPipe { diagnostics.append(contentsOf: buffer.prefix(count)) } else { data.append(contentsOf: buffer.prefix(count)) }; guard data.count + diagnostics.count <= 1_048_576 else { throw NestError.invalidResponse } }
            }
            guard [0, 1].contains(process.terminationStatus), diagnostics.isEmpty, let text = String(data: data, encoding: .utf8) else { throw NestError.unsafePath("process-use state is uncertain; keep selected data") }; return text
        } catch {
            if process.isRunning { process.terminate(); if ended.wait(timeout: .now() + 1) == .timedOut, process.isRunning { _ = kill(process.processIdentifier, SIGKILL); _ = ended.wait(timeout: .now() + 1) } }
            throw error
        }
    }
}
