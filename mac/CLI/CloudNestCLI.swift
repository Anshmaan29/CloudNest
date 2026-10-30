import Foundation
import CloudNestCore

@main
struct CLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { help(); return }
        let oauth = GoogleOAuth()
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CloudNest")
        let catalog = try Catalog(directory: base)
        let remote = DriveClient(oauth: oauth)
        // The native app stores protection in its bundle domain. The CLI has no
        // application bundle, so its standard defaults domain would differ.
        let preferences = UserDefaults(suiteName: "org.cloudnest.os")
        let protected = (preferences?.stringArray(forKey: "protectedFolders") ?? []).map { URL(fileURLWithPath: $0) }
        let safety = FileSafety(protectedRoots: protected)
        let archive = ArchiveCoordinator(catalog: catalog, remote: remote, safety: safety)
        let folders = FolderArchiveCoordinator(catalog: catalog, remote: remote, safety: safety)
        switch command {
        case "login":
            guard arguments.count == 2 else { help(); return }
            try await oauth.importClient(from: URL(fileURLWithPath: arguments[1])); try await oauth.signIn()
            print("Google authorized. Credentials saved in macOS Keychain.")
        case "revoke": try await oauth.revoke(); print("Google grant revoked.")
        case "scan":
            guard arguments.count == 2 else { help(); return }
            let report = try FileScanner(safety: safety).scan(root: URL(fileURLWithPath: arguments[1]), minimumBytes: 0)
            for file in report.candidates { print("\(file.logicalBytes)\t\(file.allocatedBytes)\t\(file.url.path)") }
            print("\(report.candidates.count) files; allocation estimate \(report.allocatedBytes) bytes; excludes \(report.excluded); truncated \(report.truncated). Guaranteed reclaimed: 0 bytes.")
        case "archive":
            guard arguments.count == 3 else { help(); return }
            let job = try await archive.enqueue(source: URL(fileURLWithPath: arguments[2]), approvedRoot: URL(fileURLWithPath: arguments[1]))
            print("Job \(job.id). Local original will be retained.")
            try await archive.run(job.id); print("File and recovery manifest verified on Drive.")
        case "archive-folder":
            guard arguments.count == 2 else { help(); return }
            let source = URL(fileURLWithPath: arguments[1])
            let job = try await folders.enqueue(source: source, approvedRoot: source)
            print("Folder job \(job.id). All originals will be retained.")
            try await folders.run(job.id)
            let manifest = await folders.manifestURL(for: job.id)
            print("Folder and portable manifest verified on Drive. Local manifest: \(manifest.path)")
        case "resume-folder":
            guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { help(); return }
            try await folders.run(id); print("Folder verified. All originals retained.")
        case "folder-jobs":
            guard arguments.count <= 2 else { help(); return }
            let offset = arguments.count == 2 ? Int(arguments[1]) : 0
            guard let offset, offset >= 0 else { throw NestError.invalidResponse }
            for job in try await folders.jobs(limit: 100, offset: offset) {
                print("\(job.id)\t\(job.state.rawValue)\t\(job.completedFiles)/\(job.totalFiles)\t\(job.totalBytes) bytes\t\(job.source.path)\t\(job.lastError ?? "")")
            }
            print("Showing at most 100 folder jobs from offset \(offset).")
        case "restore-folder":
            guard arguments.count == 3 else { help(); return }
            let manifest = try FolderArchiveManifest.read(from: URL(fileURLWithPath: arguments[1]))
            let restored = try await folders.restore(manifest: manifest, destination: URL(fileURLWithPath: arguments[2]))
            print("Folder restored and verified: \(restored.path)")
        case "search":
            guard arguments.count == 2 || arguments.count == 3 else { help(); return }
            let offset = arguments.count == 3 ? Int(arguments[2]) : 0
            guard let offset, offset >= 0 else { throw NestError.invalidResponse }
            let count = try await catalog.count(query: arguments[1])
            for job in try await catalog.search(query: arguments[1], limit: 50, offset: offset) {
                print("\(job.id)\t\(job.state.rawValue)\t\(job.snapshot.identity.size)\t\(job.source.path)")
            }
            print("\(count) matching jobs; showing at most 50 from offset \(offset).")
        case "quota":
            guard arguments.count == 1 else { help(); return }
            let quota = try await remote.storageQuota()
            print("Account usage: \(quota.usage) bytes; capacity: \(quota.limit.map(String.init) ?? "not reported"); available: \(quota.available.map(String.init) ?? "not reported").")
        case "health":
            guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { help(); return }
            let job = try await catalog.job(id)
            let report = await ArchiveHealthChecker(remote: remote).check(job)
            print("\(report.status)\t\(report.detail)")
            if report.status != .healthy { throw NestError.verificationFailed }
        case "recover-catalog":
            guard arguments.count == 1 else { help(); return }
            let report = try await remote.recoverCatalog(into: catalog)
            print("Scanned \(report.scanned); imported \(report.imported); existing \(report.existing); rejected \(report.rejected); truncated \(report.truncated). Restore-only records cannot authorize local cleanup.")
        case "recovered":
            guard arguments.count <= 3 else { help(); return }
            let query = arguments.count >= 2 ? arguments[1] : "", offset = arguments.count == 3 ? Int(arguments[2]) : 0
            guard let offset, offset >= 0 else { throw NestError.invalidResponse }
            for record in try await catalog.recoveredArchives(query: query, limit: 100, offset: offset) {
                print("\(record.id)\t\(record.manifest.size)\t\(record.manifest.fileName)\t\(record.manifestID)")
            }
            print("Showing at most 100 recovered records from offset \(offset).")
        case "restore-recovered":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[1]) else { help(); return }
            let records = try await catalog.recoveredArchives(query: id.uuidString, limit: 100)
            guard let record = records.first(where: { $0.id == id }) else { throw NestError.invalidManifest }
            let restored = try await archive.restore(manifest: record.manifest, destination: URL(fileURLWithPath: arguments[2]))
            print("Restored and verified: \(restored.path)")
        case "resume":
            guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { help(); return }
            try await archive.run(id); print("Verified. Local original retained.")
        case "jobs":
            try await archive.reconcileRecovery()
            for job in try await catalog.jobs() { print("\(job.id)\t\(job.state.rawValue)\t\(job.offset)\tlocal=\(job.recovery?.stage.rawValue ?? "original")\tobserved_free_increase=\(job.recovery?.observedFreeSpaceIncrease ?? 0)\t\(job.source.path)\t\(job.lastError ?? "")") }
        case "stage-cleanup":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[1]), arguments[2] == "--approve-local-move" else { help(); return }
            try await archive.moveToRecovery(id); print("Original moved into managed recovery. No space reclaimed by this move. Use put-back to reverse it.")
        case "remove-recovery":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[1]), arguments[2] == "--approve-permanent-removal" else { help(); return }
            try await archive.permanentlyRemoveRecovery(id)
            let job = try await catalog.job(id)
            print("Verified managed copy removed. Observed filesystem free-space increase: \(job.recovery?.observedFreeSpaceIncrease ?? 0) bytes. Cloud archive retained.")
        case "put-back":
            guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { help(); return }
            try await archive.putBackOriginal(id); print("Original put back without overwrite.")
        case "restore":
            guard arguments.count == 3 else { help(); return }
            let manifest = try ArchiveManifest.read(from: URL(fileURLWithPath: arguments[1]))
            let restored = try await archive.restore(manifest: manifest, destination: URL(fileURLWithPath: arguments[2]))
            print("Restored and verified: \(restored.path)")
        default: help()
        }
    }
    static func help() {
        print("""
        CloudNest Storage — archiving retains originals; cleanup is separately approved
        cloudnest login /path/to/desktop-oauth.json
        cloudnest scan /approved/folder
        cloudnest archive /approved/folder /approved/folder/file
        cloudnest resume JOB-UUID
        cloudnest archive-folder /approved/folder
        cloudnest resume-folder FOLDER-JOB-UUID
        cloudnest folder-jobs [offset]
        cloudnest restore-folder /path/to/folder-manifest.json /existing/parent
        cloudnest jobs
        cloudnest search "literal text" [offset]
        cloudnest quota
        cloudnest health JOB-UUID
        cloudnest recover-catalog
        cloudnest recovered [literal-text] [offset]
        cloudnest restore-recovered JOB-UUID /existing/destination
        cloudnest stage-cleanup JOB-UUID --approve-local-move
        cloudnest put-back JOB-UUID
        cloudnest remove-recovery JOB-UUID --approve-permanent-removal
        cloudnest restore /path/to/manifest.json /existing/destination/folder
        cloudnest revoke
        """)
    }
}
