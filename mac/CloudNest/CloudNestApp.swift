import SwiftUI
import AppKit
import CloudNestCore

private enum PortableManifest: Sendable {
    case file(ArchiveManifest)
    case folder(FolderArchiveManifest)
    static func read(_ url: URL) throws -> PortableManifest {
        try Task.checkCancellation()
        if let manifest = try? FolderArchiveManifest.read(from: url) { return .folder(manifest) }
        return .file(try ArchiveManifest.read(from: url))
    }
}

@main
struct CloudNestApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            MainView(model: model).frame(minWidth: 940, minHeight: 660)
                .task { await model.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refresh() } }
        }.defaultSize(width: 1120, height: 760)
        MenuBarExtra("CloudNest", systemImage: "cloud") {
            Text("CloudNest · Personal cloud")
            Text("\(model.format(model.freeBytes)) available")
            Divider()
            Button("Open CloudNest") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            Button("Scan a folder…") { model.chooseAndScan() }.disabled(model.busy)
            Divider()
            Button("Quit CloudNest", action: { NSApp.terminate(nil) }).keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection = "Overview"
    @Published var report = ScanReport()
    @Published var root: URL?
    @Published var jobs: [ArchiveJob] = []
    @Published var busy = false
    @Published var message = "Choose a folder to begin. Your files stay in place."
    @Published var errorMessage: String?
    @Published var connected = false
    @Published var authorizationChecked = false
    @Published var totalBytes: Int64 = 0
    @Published var freeBytes: Int64 = 0
    @Published var minimumMB = (UserDefaults.standard.object(forKey: "minimumMB") as? Int) ?? 25 { didSet { UserDefaults.standard.set(minimumMB, forKey: "minimumMB") } }
    @Published var minimumAgeDays = (UserDefaults.standard.object(forKey: "minimumAgeDays") as? Int) ?? 60 { didSet { UserDefaults.standard.set(minimumAgeDays, forKey: "minimumAgeDays") } }
    @Published var preset: ScanPreset = .balanced
    @Published var duplicates: [DuplicateGroup] = []
    @Published var protectedFolders: [URL] = (UserDefaults.standard.stringArray(forKey: "protectedFolders") ?? []).map { URL(fileURLWithPath: $0) }
    @Published var scanIsStale = false
    private var watcher: FolderWatcher?
    private let oauth = GoogleOAuth()
    private var catalog: Catalog?
    private var coordinator: ArchiveCoordinator?
    @Published var uploaded: Int64 = 0
    @Published var verified: Int64 = 0
    @Published var recoveryBytes: Int64 = 0
    @Published var observedFreeIncrease: Int64 = 0
    @Published var folderJobs: [FolderArchiveJob] = []
    @Published var scanProgress: ScanProgress?
    @Published var libraryQuery = ""
    @Published var libraryState = "All"
    @Published var libraryJobs: [ArchiveJob] = []
    @Published var libraryOffset = 0
    @Published var libraryCount = 0
    @Published var quota: DriveStorageQuota?
    @Published var quotaMessage: String?
    @Published var health: [UUID: ArchiveHealthReport] = [:]
    @Published var canCancel = false
    @Published var recovered: [RecoveredArchive] = []
    @Published var recoveredCount = 0
    @Published var recoveredOffset = 0
    @Published var libraryLoading = false
    private var searchGeneration = UUID()
    private var activeScanID: UUID?
    private var activeTask: Task<Void, Never>?
    private var folderCoordinator: FolderArchiveCoordinator?
    private let libraryPageSize = 50
    private var drive: DriveClient { DriveClient(oauth: oauth) }
    private func makeFolderCoordinator(_ db: Catalog) -> FolderArchiveCoordinator {
        FolderArchiveCoordinator(catalog: db, remote: drive, safety: FileSafety(protectedRoots: protectedFolders), onFolderChanged: { [weak self] job in
            await self?.folderChanged(job)
        }, onFileChanged: { [weak self] job in
            await self?.jobChanged(job)
        })
    }
    private func folderChanged(_ job: FolderArchiveJob) {
        if let index = folderJobs.firstIndex(where: { $0.id == job.id }) { folderJobs[index] = job }
        else { folderJobs.insert(job, at: 0) }
        if folderJobs.count > 100 { folderJobs.removeLast() }
        message = "Folder: \(job.source.lastPathComponent) · \(job.completedFiles) of \(job.totalFiles) files verified"
    }
    func cancelOperation() {
        guard canCancel else { return }
        canCancel = false
        message = "Pausing safely… Verified uploads and originals will be retained."
        activeTask?.cancel()
    }
    func searchLibrary(reset: Bool = true) async {
        if reset { libraryOffset = 0; recoveredOffset = 0 }
        let query = libraryQuery, state = TransferState(rawValue: libraryState.lowercased())
        let offset = libraryOffset, recoveryOffset = recoveredOffset, request = UUID()
        searchGeneration = request; libraryLoading = true
        do {
            let count = try await catalog?.count(query: query, state: state) ?? 0
            let page = try await catalog?.search(query: query, state: state, limit: libraryPageSize, offset: offset) ?? []
            let recoveryCount = try await catalog?.recoveredCount(query: query) ?? 0
            let recoveryPage = try await catalog?.recoveredArchives(query: query, limit: libraryPageSize, offset: recoveryOffset) ?? []
            guard searchGeneration == request else { return }
            libraryCount = count; libraryJobs = page; recoveredCount = recoveryCount; recovered = recoveryPage
        } catch { if searchGeneration == request { errorMessage = error.localizedDescription } }
        if searchGeneration == request { libraryLoading = false }
    }
    func libraryPage(_ direction: Int) {
        guard !busy, !libraryLoading else { return }
        libraryOffset = max(0, libraryOffset + direction * libraryPageSize)
        Task { await searchLibrary(reset: false) }
    }
    func recoveredPage(_ direction: Int) {
        guard !busy, !libraryLoading else { return }
        recoveredOffset = max(0, recoveredOffset + direction * libraryPageSize)
        Task { await searchLibrary(reset: false) }
    }
    func recoverCatalog() {
        let alert = NSAlert(); alert.messageText = "Recover the file catalog from Drive?"
        alert.informativeText = "CloudNest will read only its own remote file manifests and verify referenced cloud files. It will import restore-only records into the local catalog without scanning other Drive files or granting permission to remove local originals. This may require many metadata requests. Folder archives use their separate portable manifests."
        alert.addButton(withTitle: "Recover file catalog"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let catalog else { return }
        runTask("Reading and verifying CloudNest file manifests…", cancellable: true, successMessage: nil) {
            let report = try await self.drive.recoverCatalog(into: catalog)
            await MainActor.run {
                self.message = "Catalog recovery: \(report.imported) imported · \(report.existing) existing · \(report.rejected) rejected\(report.truncated ? " · scan limit reached" : "")"
            }
        }
    }
    func restoreRecovered(_ record: RecoveredArchive) {
        guard let coordinator else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Restore here"; panel.message = "Restore \(record.manifest.fileName). Existing files are never overwritten."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        runTask("Restoring from a recovered cloud manifest…", cancellable: true) {
            _ = try await coordinator.restore(manifest: record.manifest, destination: destination)
        }
    }
    func checkHealth(_ job: ArchiveJob) {
        runTask("Checking cloud file and recovery manifest…", cancellable: true) {
            let result = await ArchiveHealthChecker(remote: self.drive).check(job)
            await MainActor.run { self.health[job.id] = result }
        }
    }
    func refreshQuota() {
        guard connected, !busy else { return }
        runTask("Reading Google Drive quota…", cancellable: true) {
            do {
                let value = try await self.drive.storageQuota()
                await MainActor.run { self.quota = value; self.quotaMessage = nil }
            } catch {
                await MainActor.run { self.quotaMessage = "Quota unavailable. Check your connection or Google authorization." }
                throw error
            }
        }
    }
    private func makeCoordinator(_ db: Catalog) -> ArchiveCoordinator {
        ArchiveCoordinator(catalog: db, remote: DriveClient(oauth: oauth), safety: FileSafety(protectedRoots: protectedFolders), onJobChanged: { [weak self] job in
            await self?.jobChanged(job)
        })
    }
    private func jobChanged(_ job: ArchiveJob) async {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        if jobs.count > 500 { jobs.removeLast() }
        if job.state == .uploading { message = "Uploading \(job.source.lastPathComponent) · \(format(job.offset)) of \(format(job.snapshot.identity.size))" }
        try? await refreshTotals()
        await searchLibrary(reset: false)
    }
    private func refreshTotals() async throws {
        guard let totals = try await catalog?.totals() else { return }
        uploaded = totals.uploaded; verified = totals.verified
        recoveryBytes = totals.inRecovery; observedFreeIncrease = totals.observedFreeIncrease
    }
    func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    func refresh() async {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            totalBytes = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
            freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            if catalog == nil {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CloudNest", isDirectory: true)
                let db = try Catalog(directory: directory)
                catalog = db; coordinator = makeCoordinator(db); folderCoordinator = makeFolderCoordinator(db)
                try await coordinator?.reconcileRecovery()
            }
            jobs = try await catalog?.jobs() ?? []
            try await refreshTotals()
            folderJobs = try await folderCoordinator?.jobs(limit: 100) ?? []
            await searchLibrary(reset: false)
            connected = await oauth.isConnected()
            authorizationChecked = true
            if !connected { quota = nil }
        } catch is CancellationError { /* A cancelled refresh does not imply a storage failure. */ }
        catch { errorMessage = error.localizedDescription }
    }
    func chooseAndScan() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Scan folder"; panel.message = "Only this folder is approved. Repositories, databases and cloud folders are excluded."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }
    func scan(_ url: URL) {
        guard !busy else { return }
        root = url; report = ScanReport(); duplicates = []; watcher = nil; selection = "Storage"; busy = true; canCancel = true
        message = "Scanning \(url.lastPathComponent)…"; scanIsStale = false; scanProgress = nil
        let request = UUID(); activeScanID = request
        let safety = FileSafety(protectedRoots: protectedFolders), bytes = Int64(min(1_000_000_000, max(0, minimumMB))) * 1_000_000, age = min(36_500, max(0, minimumAgeDays))
        activeTask = Task {
            do {
                let scan = Task.detached(priority: .utility) { [model = self] in
                    try FileScanner(safety: safety).scan(root: url, minimumBytes: bytes, minimumAgeDays: age, onProgress: { progress in
                        Task { @MainActor [weak model] in if model?.activeScanID == request { model?.scanProgress = progress } }
                    })
                }
                report = try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
                try Task.checkCancellation()
                message = "\(report.candidates.count) files matched · \(report.excluded) excluded\(report.truncated ? " · Scan limit reached" : "")"
                watcher = try FolderWatcher(root: url) { [weak model = self] in Task { await model?.markScanStale(url) } }
            } catch is CancellationError { message = "Scan cancelled. No files were changed." }
            catch { errorMessage = error.localizedDescription }
            busy = false; canCancel = false; activeTask = nil; scanProgress = nil; activeScanID = nil
        }
    }
    private func markScanStale(_ watchedRoot: URL) { if root == watchedRoot { scanIsStale = true } }
    func findDuplicates() {
        guard let root, !busy else { return }
        let report = report, safety = FileSafety(protectedRoots: protectedFolders)
        busy = true; canCancel = true; message = "Comparing equal-size files · maximum 2 GB read…"
        activeTask = Task {
            do {
                let comparison = Task.detached(priority: .utility) { try FileScanner(safety: safety).duplicateGroups(report, root: root) }
                duplicates = try await withTaskCancellationHandler(operation: { try await comparison.value }, onCancel: { comparison.cancel() })
                message = "\(duplicates.count) duplicate groups found within the read budget. Files were not changed."
            } catch is CancellationError { message = "Duplicate comparison cancelled. No files were changed." }
            catch { errorMessage = error.localizedDescription }
            busy = false; canCancel = false; activeTask = nil
        }
    }
    func protectFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Protect folder"
        guard panel.runModal() == .OK, let url = panel.url, !protectedFolders.contains(url) else { return }
        protectedFolders.append(url); saveProtection()
    }
    func unprotect(_ url: URL) { protectedFolders.removeAll { $0 == url }; saveProtection() }
    private func saveProtection() {
        UserDefaults.standard.set(protectedFolders.map(\.path), forKey: "protectedFolders")
        if let catalog { coordinator = makeCoordinator(catalog); folderCoordinator = makeFolderCoordinator(catalog) }
        report = ScanReport(); duplicates = []
    }
    func recoverOriginal(_ job: ArchiveJob) {
        guard let coordinator else { return }
        runTask("Putting back \(job.source.lastPathComponent)…") { try await coordinator.putBackOriginal(job.id) }
    }
    func retainForCleanup(_ job: ArchiveJob) {
        guard let coordinator else { return }
        let alert = NSAlert(); alert.messageText = "Move this original into CloudNest recovery?"
        alert.informativeText = "\(job.source.path)\n\nCloudNest will reverify Drive and the source, then move exactly this file into a private recovery folder on the same volume. This step does not free space. You can put it back."
        alert.addButton(withTitle: "Move to recovery"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runTask("Reverifying archive before moving the original…") { try await coordinator.moveToRecovery(job.id) }
    }
    func removeRecovery(_ job: ArchiveJob) {
        guard let coordinator else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Permanently remove this managed recovery copy?"
        alert.informativeText = "\(job.source.lastPathComponent) · \(format(job.recovery?.retainedBytes ?? 0))\n\nThis cannot be undone locally. CloudNest will reverify the cloud file, recovery manifest and retained data first. The cloud archive will remain available for restore. APFS snapshots may retain blocks. No other file or Trash item is affected."
        alert.addButton(withTitle: "Permanently remove copy"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runTask("Reverifying the managed copy before removal…") { try await coordinator.permanentlyRemoveRecovery(job.id) }
    }
    func archive(_ candidate: Candidate) {
        guard let coordinator, let root else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "Upload \(candidate.url.lastPathComponent) to Google Drive?"
        confirmation.informativeText = "CloudNest will upload and verify this file and its recovery manifest. The local original stays in place."
        confirmation.addButton(withTitle: "Upload & verify"); confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        runTask("Uploading and verifying \(candidate.url.lastPathComponent)…", cancellable: true) {
            let job = try await coordinator.enqueue(source: candidate.url, approvedRoot: root)
            try await coordinator.run(job.id)
        }
    }
    func resume(_ job: ArchiveJob) {
        guard let coordinator else { return }
        runTask("Resuming \(job.source.lastPathComponent)…", cancellable: true) { try await coordinator.run(job.id) }
    }
    func restore(_ job: ArchiveJob) {
        guard let coordinator, let remoteID = job.remoteID, job.state == .verified else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Restore here"; panel.message = "Choose a destination. Existing files will never be overwritten."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        runTask("Downloading and verifying \(job.source.lastPathComponent)…", cancellable: true) {
            _ = try await coordinator.restore(manifest: ArchiveManifest(job: job, driveFileID: remoteID), destination: destination)
        }
    }
    func archiveFolder() {
        guard let folderCoordinator, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Archive folder"; panel.message = "Upload an entire folder with its nested files and empty folders. Originals stay in place. Protected or unsupported content blocks the archive."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Archive \(source.lastPathComponent) to Drive?"
        alert.informativeText = "CloudNest will inventory the complete folder, upload each file, and verify a portable folder manifest. Nothing will be removed locally. If a source changes, verification stops."
        alert.addButton(withTitle: "Archive & verify"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selection = "Archive Library"
        runTask("Preparing folder inventory…", cancellable: true) {
            let job = try await folderCoordinator.enqueue(source: source, approvedRoot: source)
            try await folderCoordinator.run(job.id)
        }
    }
    func resumeFolder(_ job: FolderArchiveJob) {
        guard let folderCoordinator else { return }
        runTask("Resuming folder archive…", cancellable: true) { try await folderCoordinator.run(job.id) }
    }
    func restoreFolder(_ job: FolderArchiveJob) {
        guard let folderCoordinator, !busy else { return }
        busy = true; message = "Reading the portable folder manifest…"
        Task {
            do {
                let url = await folderCoordinator.manifestURL(for: job.id)
                let manifest = try await Task.detached(priority: .utility) { try FolderArchiveManifest.read(from: url) }.value
                busy = false
                restoreFolderManifest(manifest)
            } catch { busy = false; errorMessage = error.localizedDescription }
        }
    }
    private func restoreFolderManifest(_ manifest: FolderArchiveManifest) {
        guard let folderCoordinator else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Restore folder here"; panel.message = "A new \(manifest.folderName) folder will be created here after verification. Existing items are never overwritten."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        runTask("Restoring and verifying the complete folder…", cancellable: true) { _ = try await folderCoordinator.restore(manifest: manifest, destination: destination) }
    }
    func revealFolderManifest(_ job: FolderArchiveJob) {
        guard let folderCoordinator else { return }
        Task {
            let url = await folderCoordinator.manifestURL(for: job.id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    func restoreFromManifest() {
        guard let coordinator, !busy else { return }
        let manifestPanel = NSOpenPanel(); manifestPanel.canChooseDirectories = false; manifestPanel.canChooseFiles = true
        manifestPanel.prompt = "Read recovery manifest"; manifestPanel.message = "Choose a CloudNest file or folder JSON recovery manifest. This works without an original catalog."
        guard manifestPanel.runModal() == .OK, let url = manifestPanel.url else { return }
        busy = true; canCancel = true; message = "Reading the portable recovery manifest…"
        activeTask = Task {
            do {
                let read = Task.detached(priority: .utility) { try PortableManifest.read(url) }
                let manifest = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
                try Task.checkCancellation()
                busy = false; canCancel = false; activeTask = nil
                switch manifest {
                case .folder(let folder): restoreFolderManifest(folder)
                case .file(let file):
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.prompt = "Restore here"; panel.message = "Restore \(file.fileName). Existing files are never overwritten."
                    guard panel.runModal() == .OK, let destination = panel.url else { return }
                    runTask("Restoring from a portable recovery manifest…", cancellable: true) { _ = try await coordinator.restore(manifest: file, destination: destination) }
                }
            } catch is CancellationError {
                busy = false; canCancel = false; activeTask = nil; message = "Manifest read cancelled. No files were changed."
            } catch { busy = false; canCancel = false; activeTask = nil; errorMessage = error.localizedDescription }
        }
    }
    func importOAuth() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "Select the Desktop App OAuth JSON downloaded from Google Cloud project cloudnest-os. It is stored in Keychain."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runTask("Importing OAuth client…") { try await self.oauth.importClient(from: url) }
    }
    func signIn() { runTask("Waiting for Google sign-in in your browser…") { try await self.oauth.signIn() } }
    func revoke() {
        let alert = NSAlert(); alert.messageText = "Revoke CloudNest's Google access?"
        alert.informativeText = "This revokes grants for the configured Google project. Archived files remain in Drive."
        alert.addButton(withTitle: "Revoke access"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runTask("Revoking Google access…") { try await self.oauth.revoke() }
    }
    private func runTask(_ text: String, cancellable: Bool = false, successMessage: String? = "Completed. Review archive status and any retained originals in Archive Library.", operation: @escaping @Sendable () async throws -> Void) {
        guard !busy else { return }; busy = true; message = text; canCancel = cancellable
        activeTask = Task {
            do { try await operation(); try Task.checkCancellation(); if let successMessage { message = successMessage } }
            catch is CancellationError { message = "Paused safely. Originals are retained; use Resume to continue an upload." }
            catch {
                if Task.isCancelled { message = "Paused safely. Originals are retained; use Resume to continue an upload." }
                else { errorMessage = (error as? NestError)?.localizedDescription ?? (error as? DriveServiceError)?.localizedDescription ?? "The operation was interrupted. Review the queue and retry." }
            }
            // Cancellation belongs to the operation, not the durable-state reload.
            await Task { @MainActor in await self.refresh() }.value
            busy = false; canCancel = false; activeTask = nil
        }
    }

}

struct MainView: View {
    @ObservedObject var model: AppModel
    private let accent = Color(red: 0.48, green: 0.55, blue: 1)
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "cloud.fill").font(.title).foregroundStyle(accent)
                    VStack(alignment: .leading) { Text("CloudNest").font(.headline); Text("PERSONAL CLOUD").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).tracking(2) }
                }.padding(.top, 22).padding(.horizontal, 14)
                List(selection: $model.selection) {
                    Label("Overview", systemImage: "square.grid.2x2").tag("Overview")
                    Label("Storage", systemImage: "internaldrive").tag("Storage")
                    Label("Archive Library", systemImage: "archivebox").tag("Archive Library")
                    Label("Settings & Security", systemImage: "lock.shield").tag("Settings")
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Originals protected", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
                    Text("STORAGE PREVIEW").font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(.tertiary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(210)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(model.selection == "Settings" ? "Settings & Security" : model.selection).font(.headline)
                    Spacer()
                    Label(!model.authorizationChecked ? "Checking Drive authorization…" : (model.connected ? "Drive authorized" : "Drive not connected"), systemImage: model.connected ? "checkmark.circle.fill" : "circle.dotted").font(.caption).foregroundStyle(model.connected ? .green : .secondary)
                    if model.busy { ProgressView().controlSize(.small).padding(.leading, 8) }
                    if model.canCancel { Button("Pause", action: model.cancelOperation).help("Pause this operation safely. Uploads can be resumed; originals stay in place.").keyboardShortcut(".", modifiers: .command) }
                }.padding(.horizontal, 30).padding(.vertical, 18)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.selection == "Overview" { overview }
                        else if model.selection == "Storage" { storage }
                        else if model.selection == "Archive Library" { archiveLibrary }
                        else { settings }
                    }.padding(30)
                }
                Divider()
                HStack { Image(systemName: "shield.lefthalf.filled").foregroundStyle(accent); Text(model.message).lineLimit(2); Spacer(); Text("No background polling").foregroundStyle(.tertiary) }.font(.caption).padding(14)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .alert("CloudNest", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .toolbar {
            Button(action: model.restoreFromManifest) { Label("Restore from manifest…", systemImage: "arrow.down.doc") }.disabled(model.busy || !model.connected)
            Button(action: model.archiveFolder) { Label("Archive folder…", systemImage: "archivebox") }.disabled(model.busy || !model.connected)
            Button(action: model.chooseAndScan) { Label("Scan folder", systemImage: "folder.badge.plus") }.disabled(model.busy).keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
    private var overview: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("A little more room.\nA lot more possibility.").font(.system(size: 34, weight: .semibold)).tracking(-1)
                Text("Your files, safely in reach. Start with a folder you choose.").foregroundStyle(.secondary)
            }.padding(.vertical, 8)
            panel {
                HStack(alignment: .firstTextBaseline) { Label("Mac storage", systemImage: "internaldrive").font(.headline); Spacer(); Text("\(model.format(model.freeBytes)) available").foregroundStyle(.secondary) }
                ProgressView(value: Double(max(0, model.totalBytes - model.freeBytes)), total: Double(max(1, model.totalBytes))).tint(accent).padding(.vertical, 12)
                HStack { Text("\(model.format(model.totalBytes - model.freeBytes)) used"); Spacer(); Text("\(model.format(model.totalBytes)) capacity") }.font(.caption).foregroundStyle(.secondary)
            }
            quotaPanel
            HStack(spacing: 16) {
                metric("Uploaded", value: model.format(model.uploaded), note: "Data acknowledged by Drive", icon: "arrow.up.right")
                metric("Verified", value: model.format(model.verified), note: "File + recovery manifest", icon: "checkmark.seal")
                metric("In recovery", value: model.format(model.recoveryBytes), note: "Local bytes still retained", icon: "arrow.uturn.backward")
                metric("Free-space increase", value: model.format(model.observedFreeIncrease), note: "Observed during managed removal", icon: "leaf")
            }
            panel {
                Label("Start small. Verify everything.", systemImage: "checkmark.shield").font(.headline)
                Text("Review a folder, verify an archive, then test a restore. Original files stay in place until you separately approve a move into recovery and permanent removal.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Choose a folder…", action: model.chooseAndScan).buttonStyle(.borderedProminent).disabled(model.busy).padding(.top, 8)
            }
        }
    }
    private var storage: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("Make room, with confidence.").font(.largeTitle.bold())
                Text(model.root?.path ?? "Scan only the folders you approve.").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            panel {
                HStack {
                    Picker("Rules", selection: $model.preset) { ForEach(ScanPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 220)
                        .onChange(of: model.preset) { _, value in model.minimumMB = Int(value.minimumBytes / 1_000_000); model.minimumAgeDays = value.minimumAgeDays }
                    Spacer()
                    Text("Minimum MB").font(.caption)
                    TextField("MB", value: $model.minimumMB, format: .number).frame(width: 70)
                    Text("Modified ≥ days ago").font(.caption)
                    TextField("Days", value: $model.minimumAgeDays, format: .number).frame(width: 60)
                }
                HStack {
                    Text("Rules produce recommendations only. No autonomous operations.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let root = model.root { Button(model.scanIsStale ? "Folder changed · Rescan" : "Rescan") { model.scan(root) }.disabled(model.busy) }
                    Button("Find duplicates", action: model.findDuplicates).disabled(model.busy || model.root == nil || model.report.candidates.isEmpty)
                }
            }.disabled(model.busy)
            if let progress = model.scanProgress {
                panel {
                    HStack { ProgressView().controlSize(.small); Text("\(progress.visited) items visited · \(progress.matched) matches · \(progress.excluded) excluded").font(.callout).monospacedDigit() }
                    Text("Only the selected folder is being inspected. You can pause without changing any files.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack { metric("Scan allocation estimate", value: model.format(model.report.allocatedBytes), note: "APFS snapshots and clones affect reclaim", icon: "chart.bar"); metric("Eligible files", value: String(model.report.candidates.count), note: "Manual review before archiving", icon: "doc.on.doc") }
            if !model.duplicates.isEmpty {
                panel {
                    Label("Content duplicates", systemImage: "doc.on.doc").font(.headline)
                    ForEach(model.duplicates) { group in
                        Text("\(group.files.count) matching files · \(model.format(group.logicalBytesPerFile)) each").font(.subheadline)
                        ForEach(group.files, id: \.path) { Text($0.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Divider()
                    }
                    Text("SHA-256 matches within a 2 GB read budget. Hard links are counted once. No duplicate has been deleted.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.report.candidates.isEmpty {
                panel {
                    Text("Files to review").font(.headline)
                    ForEach(model.report.candidates.prefix(200)) { file in
                        HStack {
                            Image(systemName: file.category == "Media" ? "film" : "doc.zipper").font(.title3).foregroundStyle(accent).frame(width: 32)
                            VStack(alignment: .leading, spacing: 4) { Text(file.url.lastPathComponent).lineLimit(1); Text("\(file.category) · Modified \(file.modified.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(model.format(file.logicalBytes)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Archive") { model.archive(file) }.disabled(!model.connected || model.busy)
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    if model.report.candidates.count > 200 { Text("Showing the largest 200 files. Scan a narrower folder to review the rest.").font(.caption).foregroundStyle(.secondary) }
                }
            } else { ContentUnavailableView("No matching files", systemImage: "folder", description: Text("Choose a folder or adjust size and modified-age rules. Scanning never changes a file.")) }
            if !model.jobs.isEmpty || !model.folderJobs.isEmpty {
                panel {
                    Label("Your archives", systemImage: "archivebox").font(.headline)
                    Text("Search uploads, review verification and recovery status, or restore from Archive Library.").foregroundStyle(.secondary)
                    Button("Open Archive Library") { model.selection = "Archive Library" }
                }
            }
        }
    }
    private var quotaPanel: some View {
        panel {
            HStack {
                Label("Google Drive", systemImage: "externaldrive.badge.icloud").font(.headline)
                Spacer()
                Button("Refresh quota", action: model.refreshQuota).disabled(model.busy || !model.connected)
            }
            if let quota = model.quota {
                if let limit = quota.limit {
                    ProgressView(value: Double(min(quota.usage, limit)), total: Double(max(1, limit))).tint(accent)
                    HStack { Text("\(model.format(quota.usage)) used"); Spacer(); Text("\(model.format(quota.available ?? 0)) available of \(model.format(limit))") }.font(.caption).foregroundStyle(.secondary)
                } else { Text("\(model.format(quota.usage)) used · Google did not report a capacity limit").font(.callout).foregroundStyle(.secondary) }
                Text("Account-wide quota reported by Google. Drive trash and other Google services can use this capacity.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(model.quotaMessage ?? (model.connected ? "Refresh to read your current cloud capacity. Quota is never polled in the background." : "Connect Google Drive in Settings to read cloud capacity.")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private var archiveLibrary: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("Safely stored. Easy to find.").font(.largeTitle.bold())
                Text("Verified archives and recoverable local copies, with their status kept separate.").foregroundStyle(.secondary)
            }
            panel {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search file name, original path or job ID", text: $model.libraryQuery)
                        .textFieldStyle(.plain).onSubmit { Task { await model.searchLibrary() } }
                        .accessibilityLabel("Search archive library")
                    Button("Search") { Task { await model.searchLibrary() } }.keyboardShortcut(.return, modifiers: .command)
                    Picker("Status", selection: $model.libraryState) {
                        Text("All states").tag("All")
                        Text("Queued").tag("Queued")
                        Text("Uploading").tag("Uploading")
                        Text("Uploaded").tag("Uploaded")
                        Text("Verified").tag("Verified")
                    }.frame(width: 185).onChange(of: model.libraryState) { _, _ in Task { await model.searchLibrary() } }
                }
                HStack {
                    Text("\(model.libraryCount) file jobs · \(model.recoveredCount) recovered records").font(.caption).foregroundStyle(.secondary)
                    if model.libraryLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Recover file catalog…", action: model.recoverCatalog).disabled(model.busy || !model.connected)
                    Button("Restore from manifest…", action: model.restoreFromManifest).disabled(model.busy || !model.connected)
                    Button("Archive folder…", action: model.archiveFolder).buttonStyle(.borderedProminent).disabled(model.busy || !model.connected)
                }
            }
            if !model.folderJobs.isEmpty {
                panel {
                    Label("Folder archives · latest 100", systemImage: "folder.badge.checkmark").font(.headline)
                    Text("Folder archives retain all originals. Protected or unsupported entries stop the archive; folder cleanup is not offered.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.folderJobs.prefix(100)) { job in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                Image(systemName: "folder").font(.title2).foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.source.lastPathComponent).font(.headline)
                                    Text(job.lastError ?? "\(job.state.rawValue.capitalized) · \(job.completedFiles) of \(job.totalFiles) files · \(model.format(job.totalBytes))").font(.caption).foregroundStyle(job.lastError == nil ? Color.secondary : Color.orange)
                                    Text(job.source.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                if job.state == .verified {
                                    Button("Manifest") { model.revealFolderManifest(job) }.disabled(model.busy)
                                    Button("Restore folder…") { model.restoreFolder(job) }.disabled(model.busy || !model.connected)
                                } else { Button("Resume / verify") { model.resumeFolder(job) }.disabled(model.busy || !model.connected) }
                            }
                            if job.state != .verified && job.totalFiles > 0 { ProgressView(value: Double(job.completedFiles), total: Double(job.totalFiles)).accessibilityLabel("Verified files") }
                        }.padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            if !model.recovered.isEmpty {
                panel {
                    Label("Recovered from Drive", systemImage: "arrow.clockwise.icloud").font(.headline)
                    Text("Restore-only records verified during recovery. They never authorize removal of a local original. Status filters apply to file jobs below; these recovered records are verified manifests.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recovered) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.manifest.fileName).font(.headline)
                                Text("\(model.format(record.manifest.size)) · Verified \(record.verifiedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore…") { model.restoreRecovered(record) }.disabled(model.busy || !model.connected)
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    HStack {
                        Text("Showing \(model.recoveredOffset + 1)–\(model.recoveredOffset + model.recovered.count) of \(model.recoveredCount)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Previous recovered") { model.recoveredPage(-1) }.disabled(model.busy || model.libraryLoading || model.recoveredOffset == 0)
                        Button("Next recovered") { model.recoveredPage(1) }.disabled(model.busy || model.libraryLoading || model.recoveredOffset + model.recovered.count >= model.recoveredCount)
                    }
                }
            }
            if model.libraryJobs.isEmpty {
                ContentUnavailableView("No matching file archives", systemImage: "archivebox", description: Text("Archive a file from Storage, upload a folder, or change your search. Recovery manifests work even without the original catalog."))
            } else {
                panel {
                    Label("File archives", systemImage: "doc.on.doc").font(.headline)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.libraryJobs) { job in archiveRow(job); Divider() }
                    }
                    HStack {
                        Text("Showing \(model.libraryOffset + 1)–\(model.libraryOffset + model.libraryJobs.count) of \(model.libraryCount)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Previous") { model.libraryPage(-1) }.disabled(model.busy || model.libraryLoading || model.libraryOffset == 0)
                        Button("Next") { model.libraryPage(1) }.disabled(model.busy || model.libraryLoading || model.libraryOffset + model.libraryJobs.count >= model.libraryCount)
                    }
                }
            }
        }
    }
    private func archiveRow(_ job: ArchiveJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: job.state == .verified ? "checkmark.seal" : "doc.badge.clock").font(.title3).foregroundStyle(job.state == .verified ? .green : accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.source.lastPathComponent).font(.headline).lineLimit(1)
                    Text(job.lastError ?? "\(job.state.rawValue.capitalized) · \(model.format(job.offset)) of \(model.format(job.snapshot.identity.size))").font(.caption).foregroundStyle(job.lastError == nil ? Color.secondary : Color.orange)
                    Text(job.source.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    if let recovery = job.recovery {
                        Text("Local: \(recovery.stage.rawValue) · \(model.format(recovery.retainedBytes)) retained").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(job.folderArchiveID == nil ? "Local original retained at archive time" : "Folder member · original retained; folder cleanup unavailable").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if job.state == .verified {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack {
                            Button("Check health") { model.checkHealth(job) }
                            Button("Restore…") { model.restore(job) }
                        }.disabled(model.busy || !model.connected)
                        if job.recovery == nil && job.folderArchiveID == nil { Button("Reclaim…") { model.retainForCleanup(job) }.disabled(model.busy || !model.connected) }
                        else if job.recovery?.stage == .retained || job.recovery?.stage == .needsReview {
                            HStack {
                                Button("Put back") { model.recoverOriginal(job) }.disabled(model.busy)
                                if job.recovery?.stage == .retained { Button("Remove copy…", role: .destructive) { model.removeRecovery(job) }.disabled(model.busy || !model.connected) }
                            }
                        }
                    }
                } else { Button("Resume / verify") { model.resume(job) }.disabled(model.busy || !model.connected) }
            }
            if job.state == .uploading && job.snapshot.identity.size > 0 {
                ProgressView(value: Double(job.offset), total: Double(job.snapshot.identity.size)).accessibilityLabel("Uploaded bytes")
            }
            if let report = model.health[job.id] {
                HStack(alignment: .top) {
                    Image(systemName: report.status == .healthy ? "checkmark.shield" : "exclamationmark.shield").foregroundStyle(report.status == .healthy ? .green : .orange)
                    Text(report.detail).textSelection(.enabled)
                    Spacer()
                    Text(report.checkedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }.padding(.vertical, 12)
    }

    private var settings: some View {
        Group {
            Text("Your cloud. Your control.").font(.largeTitle.bold())
            panel {
                Label("Google Drive", systemImage: "externaldrive.badge.icloud").font(.headline)
                Text("Use Google Cloud project cloudnest-os with a Desktop App OAuth client. CloudNest requests drive.file access for files it creates. Client configuration, credentials and upload sessions are stored in macOS Keychain.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Import OAuth JSON…", action: model.importOAuth)
                    Button("Sign in with Google", action: model.signIn).buttonStyle(.borderedProminent)
                    if model.connected { Button("Revoke access", role: .destructive, action: model.revoke) }
                }.disabled(model.busy).padding(.top, 8)
                Link("Google Cloud setup", destination: URL(string: "https://console.cloud.google.com/auth/clients?project=cloudnest-os")!).font(.caption)
            }
            panel {
                Label("Safety defaults", systemImage: "lock.shield").font(.headline)
                Text("Manual scans only. One upload at a time. Rules are dry-run recommendations. Cleanup requires two separate approvals and fresh integrity checks. No symlinks, repositories, live databases, system folders, Photos libraries or cloud placeholders.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Restore always asks for a destination and verifies content before an exclusive, no-overwrite install.").foregroundStyle(.secondary)
            }
            panel {
                Label("Protected folders", systemImage: "folder.badge.minus").font(.headline)
                Text("These folders and their descendants cannot be scanned, archived or removed by CloudNest.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.protectedFolders, id: \.path) { url in
                    HStack { Text(url.path).font(.caption).textSelection(.enabled); Spacer(); Button("Remove protection") { model.unprotect(url) }.disabled(model.busy) }
                }
                Button("Add protected folder…", action: model.protectFolder).disabled(model.busy)
            }
            panel {
                Label("Brain feasibility service", systemImage: "network").font(.headline)
                Text("The remote read-only connection test passed with Codex. Your personal memory vault has not been configured yet. Storage works independently.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.07)))
    }
    private func metric(_ title: String, value: String, note: String, icon: String) -> some View {
        panel {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
