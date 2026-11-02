import Foundation
import CloudNestCore

@main
struct CLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    private static func recordActivity(_ ledger: ActivityLedger, _ event: StorageActivity) async {
        do { try await ledger.append(event) }
        catch { FileHandle.standardError.write(Data("Activity history could not be updated; review the archive catalog for durable state.\n".utf8)) }
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
        let defaults = preferences ?? .standard
        let policy = try CloudNestPreferences.transferPolicy(from: defaults)
        let rules = try CloudNestPreferences.recommendationRules(from: defaults)
        let ledger = try ActivityLedger(directory: base)
        let controlled: any ArchiveRemote
        if policy.enabled {
            let environment = SystemTransferEnvironment()
            controlled = try PolicyArchiveRemote(remote: remote, policy: policy, environment: { try await environment.current() })
        } else { controlled = remote }
        let record: @Sendable (ArchiveJob) async -> Void = { job in
            if job.state == .verified { try? await ledger.append(StorageActivity(kind: .archiveVerified, title: job.source.lastPathComponent, jobID: job.id, bytes: job.snapshot.identity.size), deduplicationKey: "verified-" + job.id.uuidString) }
        }
        let archive = ArchiveCoordinator(catalog: catalog, remote: controlled, safety: safety, onJobChanged: record)
        let folders = FolderArchiveCoordinator(catalog: catalog, remote: controlled, safety: safety, onFolderChanged: { job in
            if job.state == .verified { try? await ledger.append(StorageActivity(kind: .folderVerified, title: job.source.lastPathComponent, jobID: job.id, bytes: job.totalBytes), deduplicationKey: "folder-verified-" + job.id.uuidString) }
        }, onFileChanged: record)
        switch command {
        case "login":
            guard arguments.count == 2 else { help(); return }
            try await oauth.importClient(from: URL(fileURLWithPath: arguments[1])); try await oauth.signIn()
            print("Google authorized. Credentials saved in macOS Keychain.")
        case "revoke": try await oauth.revoke(); print("Google grant revoked.")
        case "scan":
            guard arguments.count == 2 else { help(); return }
            let report = rules.filter(try FileScanner(safety: safety).scan(root: URL(fileURLWithPath: arguments[1]), minimumBytes: 0))
            for file in report.candidates { print("\(file.logicalBytes)\t\(file.allocatedBytes)\t\(file.url.path)") }
            print("\(report.candidates.count) files; allocation estimate \(report.allocatedBytes) bytes; excludes \(report.excluded); truncated \(report.truncated). Guaranteed reclaimed: 0 bytes.")
        case "recommend":
            guard arguments.count == 2 else { help(); return }
            let report = rules.filter(try FileScanner(safety: safety).scan(root: URL(fileURLWithPath: arguments[1]), minimumBytes: 0))
            for item in SpaceRescue.rank(report).prefix(200) { print("\(item.rank)\t\(item.candidate.allocatedBytes)\t\(item.candidate.url.path)\t\(item.reason)") }
            print("Allocation estimate only; APFS snapshots/clones affect actual reclamation. No files changed.")
        case "activity":
            guard arguments.count <= 2 else { help(); return }
            let offset = arguments.count == 2 ? Int(arguments[1]) : 0
            guard let offset, offset >= 0 else { throw NestError.invalidResponse }
            for event in try await ledger.events(limit: 100, offset: offset) { print("\(event.timestamp.ISO8601Format())\t\(event.kind.rawValue)\t\(event.title)\tbytes=\(event.bytes)\tobserved_free=\(event.observedFreeBytes)") }
        case "policy":
            guard arguments.count == 1 else { help(); return }
            print("Transfer policies: \(policy.enabled ? "enabled" : "disabled"); external power: \(policy.requireExternalPower); allow expensive network: \(policy.allowExpensiveNetworks); allow constrained network: \(policy.allowConstrainedNetworks); pause in low power: \(policy.pauseInLowPowerMode); upload bytes/s: \(policy.uploadBytesPerSecond); retries: \(policy.maximumRetries). Configure in the native Settings.")
        case "archive":
            guard arguments.count == 3 else { help(); return }
            let job = try await archive.enqueue(source: URL(fileURLWithPath: arguments[2]), approvedRoot: URL(fileURLWithPath: arguments[1]))
            print("Job \(job.id). Local original will be retained.")
            try await archive.run(job.id); print("File and recovery manifest verified on Drive.")
        case "park-model":
            guard arguments.count == 2 else { help(); return }
            let preview = try ModelParking.preview(source: URL(fileURLWithPath: arguments[1]), safety: safety)
            try ModelParking.revalidate(preview, safety: safety)
            if preview.isDirectory {
                let job = try await folders.enqueue(source: preview.source, approvedRoot: preview.approvedRoot, purpose: .modelParking)
                print("Model folder job \(job.id). Originals retained; cloud storage does not run models.")
                try await folders.run(job.id)
                print("Model folder and recovery manifest verified on Drive.")
            } else {
                let job = try await archive.enqueue(source: preview.source, approvedRoot: preview.approvedRoot, purpose: .modelParking)
                print("Model job \(job.id). Original retained; cloud storage does not run models.")
                try await archive.run(job.id)
                print("Model and recovery manifest verified on Drive.")
            }
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
            await recordActivity(ledger, StorageActivity(kind: .restored, title: manifest.folderName, jobID: manifest.id, bytes: manifest.files.reduce(0) { $0 + $1.manifest.size }))
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
            await recordActivity(ledger, StorageActivity(kind: .restored, title: record.manifest.fileName, jobID: record.id, bytes: record.manifest.size))
            print("Restored and verified: \(restored.path)")
        case "resume":
            guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { help(); return }
            try await archive.run(id); print("Verified. Local original retained.")
        case "jobs":
            try await archive.reconcileRecovery()
            for job in try await catalog.jobs() { print("\(job.id)\t\(job.state.rawValue)\t\(job.offset)\tlocal=\(job.recovery?.stage.rawValue ?? "original")\tobserved_free_increase=\(job.recovery?.observedFreeSpaceIncrease ?? 0)\t\(job.source.path)\t\(job.lastError ?? "")") }
        case "folder-health":
            guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { help(); return }
            let result = await folders.health(id); print("\(result.status.rawValue)\t\(result.detail)")
            if result.status != .healthy { throw NestError.verificationFailed }
        case "stage-folder-cleanup":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[1]), arguments[2] == "--approve-local-move" else { help(); return }
            try await folders.moveToRecovery(id)
            let job = try await folders.job(id); await recordActivity(ledger, StorageActivity(kind: .recoveryStaged, title: job.source.lastPathComponent, jobID: id, bytes: job.totalBytes))
            print("Whole folder retained in managed recovery. No space reclaimed by this move.")
        case "put-back-folder":
            guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { help(); return }
            try await folders.putBackOriginal(id)
            let job = try await folders.job(id); await recordActivity(ledger, StorageActivity(kind: .putBack, title: job.source.lastPathComponent, jobID: id))
            print("Retained folder put back without overwrite.")
        case "remove-folder-recovery":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[1]), arguments[2] == "--approve-permanent-removal" else { help(); return }
            try await folders.permanentlyRemoveRecovery(id)
            let result = try await folders.job(id)
            await recordActivity(ledger, StorageActivity(kind: .removed, title: result.source.lastPathComponent, jobID: id, bytes: result.totalBytes, observedFreeBytes: result.recovery?.observedFreeSpaceIncrease ?? 0))
            print("Managed folder removed after verification. Observed free-space increase: \(result.recovery?.observedFreeSpaceIncrease ?? 0) bytes. Cloud archive retained.")
        case "recover-folder-catalog":
            let result = try await remote.recoverFolderCatalog(into: catalog)
            print("Scanned \(result.scanned); imported \(result.imported); existing \(result.existing); rejected \(result.rejected); truncated \(result.truncated). Folder groups are restore-only.")
        case "recovered-folders":
            let query = arguments.count > 1 ? arguments[1] : ""
            for record in try await catalog.recoveredFolders(query: query, limit: 100) { print("\(record.id)\t\(record.folderName)\t\(record.fileCount)\t\(record.totalBytes)") }
        case "restore-recovered-folder":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[1]) else { help(); return }
            let record = try await catalog.recoveredFolder(id)
            let restored = try await folders.restore(manifest: record.manifest, destination: URL(fileURLWithPath: arguments[2]))
            await recordActivity(ledger, StorageActivity(kind: .restored, title: record.manifest.folderName, jobID: id, bytes: record.manifest.files.reduce(0) { $0 + $1.manifest.size }))
            print("Recovered folder restored and verified: \(restored.path)")
        case "stage-cleanup":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[1]), arguments[2] == "--approve-local-move" else { help(); return }
            try await archive.moveToRecovery(id)
            let job = try await catalog.job(id); await recordActivity(ledger, StorageActivity(kind: .recoveryStaged, title: job.source.lastPathComponent, jobID: id, bytes: job.snapshot.identity.size))
            print("Original moved into managed recovery. No space reclaimed by this move. Use put-back to reverse it.")
        case "remove-recovery":
            guard arguments.count == 3, let id = UUID(uuidString: arguments[1]), arguments[2] == "--approve-permanent-removal" else { help(); return }
            try await archive.permanentlyRemoveRecovery(id)
            let job = try await catalog.job(id)
            await recordActivity(ledger, StorageActivity(kind: .removed, title: job.source.lastPathComponent, jobID: id, observedFreeBytes: job.recovery?.observedFreeSpaceIncrease ?? 0))
            print("Verified managed copy removed. Observed filesystem free-space increase: \(job.recovery?.observedFreeSpaceIncrease ?? 0) bytes. Cloud archive retained.")
        case "put-back":
            guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else { help(); return }
            try await archive.putBackOriginal(id)
            let job = try await catalog.job(id); await recordActivity(ledger, StorageActivity(kind: .putBack, title: job.source.lastPathComponent, jobID: id))
            print("Original put back without overwrite.")
        case "restore":
            guard arguments.count == 3 else { help(); return }
            let manifest = try ArchiveManifest.read(from: URL(fileURLWithPath: arguments[1]))
            let restored = try await archive.restore(manifest: manifest, destination: URL(fileURLWithPath: arguments[2]))
            await recordActivity(ledger, StorageActivity(kind: .restored, title: manifest.fileName, jobID: manifest.jobID, bytes: manifest.size))
            print("Restored and verified: \(restored.path)")
        default: help()
        }
    }
    static func help() {
        print("""
        CloudNest Storage — archiving retains originals; cleanup is separately approved
        cloudnest login /path/to/desktop-oauth.json
        cloudnest scan /approved/folder
        cloudnest recommend /approved/folder
        cloudnest activity [offset]
        cloudnest policy
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
        cloudnest folder-health FOLDER-JOB-UUID
        cloudnest stage-folder-cleanup FOLDER-JOB-UUID --approve-local-move
        cloudnest put-back-folder FOLDER-JOB-UUID
        cloudnest remove-folder-recovery FOLDER-JOB-UUID --approve-permanent-removal
        cloudnest recover-folder-catalog
        cloudnest recovered-folders [literal-query]
        cloudnest restore-recovered-folder FOLDER-JOB-UUID /existing/destination
        cloudnest stage-cleanup JOB-UUID --approve-local-move
        cloudnest put-back JOB-UUID
        cloudnest remove-recovery JOB-UUID --approve-permanent-removal
        cloudnest restore /path/to/manifest.json /existing/destination/folder
        cloudnest revoke
        """)
    }
}
