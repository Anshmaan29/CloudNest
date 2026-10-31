// Disk-backed transport for resource measurement only. Never used by the app.
import Foundation
import CryptoKit
import CloudNestCore

actor DiskRemote: ArchiveRemote {
    let root: URL
    init(root: URL) { self.root = root }
    func allocateID() -> String { UUID().uuidString }
    func begin(id: String, name: String, size: Int64, jobID: UUID) throws -> URL {
        let file = root.appendingPathComponent(id)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw NestError.conflict }
        return file
    }
    func status(session: URL, total: Int64) throws -> UploadProgress {
        let size = (try FileManager.default.attributesOfItem(atPath: session.path)[.size] as! NSNumber).int64Value
        return UploadProgress(offset: size, complete: size == total)
    }
    func send(session: URL, data: Data, offset: Int64, total: Int64) throws -> UploadProgress {
        let file = try FileHandle(forWritingTo: session); defer { try? file.close() }
        try autoreleasepool { try file.seek(toOffset: UInt64(offset)); try file.write(contentsOf: data) }
        return UploadProgress(offset: offset + Int64(data.count), complete: offset + Int64(data.count) == total)
    }
    func metadata(id: String) throws -> RemoteFile {
        let file = root.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw NestError.http(404) }
        let snapshot = try FileSafety().snapshot(file, root: root)
        return RemoteFile(id: id, size: String(snapshot.identity.size), sha256Checksum: snapshot.sha256)
    }
    func storeManifest(_ manifest: ArchiveManifest) throws -> String {
        let id = UUID().uuidString; try manifest.encoded().write(to: root.appendingPathComponent(id), options: .withoutOverwriting); return id
    }
    func download(id: String, into destination: FileHandle, maximumBytes: Int64) throws {
        let input = try FileHandle(forReadingFrom: root.appendingPathComponent(id)); defer { try? input.close() }
        var written: Int64 = 0
        while try autoreleasepool(invoking: {
            guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            written += Int64(data.count); guard written <= maximumBytes else { throw NestError.verificationFailed }
            try destination.write(contentsOf: data); return true
        }) {}
        guard written == maximumBytes else { throw NestError.verificationFailed }
    }
}
actor EphemeralSecrets: SecretStore {
    var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { values[key] }
    func write(_ key: String, value: Data) { values[key] = value }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}
@main struct PipelineBenchmark {
    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "catalog" {
            guard let count = Int(CommandLine.arguments[3]), (1...100_000).contains(count) else { throw NestError.invalidResponse }
            try await catalogBenchmark(directory: URL(fileURLWithPath: CommandLine.arguments[2]), count: count); return
        }
        guard CommandLine.arguments.count == 3 else { print("Usage: cloudnest-bench /approved/source/file /new/benchmark/directory"); return }
        let source = URL(fileURLWithPath: CommandLine.arguments[1]), directory = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw NestError.conflict }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let remoteRoot = directory.appendingPathComponent("remote"), restoreRoot = directory.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: false)
        let catalog = try Catalog(directory: directory.appendingPathComponent("catalog"))
        let coordinator = ArchiveCoordinator(catalog: catalog, remote: DiskRemote(root: remoteRoot), secrets: EphemeralSecrets())
        let start = ProcessInfo.processInfo.systemUptime
        let job = try await coordinator.enqueue(source: source, approvedRoot: source.deletingLastPathComponent())
        try await coordinator.run(job.id)
        let completed = try await catalog.job(job.id)
        _ = try await coordinator.restore(manifest: ArchiveManifest(job: completed, driveFileID: completed.remoteID!), destination: restoreRoot)
        print("Disk-backed benchmark (not Google Drive): \(job.snapshot.identity.size) bytes archived and restored, state=\(completed.state.rawValue), elapsed=\(ProcessInfo.processInfo.systemUptime - start)s. Original retained.")
    }
    static func catalogBenchmark(directory: URL, count: Int) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { throw NestError.conflict }
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = directory.appendingPathComponent("synthetic-source.txt")
        try Data("Synthetic catalog benchmark only.\n".utf8).write(to: source, options: .withoutOverwriting)
        let snapshot = try FileSafety().snapshot(source, root: directory)
        let catalog = try Catalog(directory: directory.appendingPathComponent("catalog"))
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            try Task.checkCancellation()
            var job = ArchiveJob(source: directory.appendingPathComponent("synthetic-\(index)-literal_[%].txt"), approvedRoot: directory, snapshot: snapshot)
            if index % 2 == 0 { job.state = .verified; job.remoteID = "benchmark-\(index)"; job.manifestID = "manifest-\(index)" }
            try await catalog.save(job)
        }
        let inserted = ProcessInfo.processInfo.systemUptime
        let page = try await catalog.search(query: "literal_[%]", limit: 50)
        let matches = try await catalog.count(query: "literal_[%]")
        let next = try await catalog.search(query: "literal_[%]", limit: 50, offset: 50)
        guard matches == count, page.count == min(50,count), Set(page.map(\.id)).isDisjoint(with: Set(next.map(\.id))) else { throw NestError.verificationFailed }
        let queryEnd = ProcessInfo.processInfo.systemUptime
        _ = try await catalog.totals()
        let finish = ProcessInfo.processInfo.systemUptime
        print("Synthetic catalog only; no cloud requests or user files. rows=\(count), insert_seconds=\(inserted-start), two_pages_and_count_seconds=\(queryEnd-inserted), totals_seconds=\(finish-queryEnd), page_limit=50")
    }

}
