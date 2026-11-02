import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
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
    @NSApplicationDelegateAdaptor(CloudNestServices.self) private var services
    var body: some Scene {
        WindowGroup {
            MainView(model: model).frame(minWidth: 940, minHeight: 660)
                .task {
                    await model.refresh()
                    services.installHandler { [weak model = model] url, restore in model?.reviewSelectedURL(url, restore: restore) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refresh() } }
        }.defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Commands…") { model.showCommands = true }.keyboardShortcut("k", modifiers: .command)
                Button("Search archives") { model.selection = "Archive Library" }.keyboardShortcut("f", modifiers: .command)
                Button("Free Up Space") { model.selection = "Free Up Space" }.keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
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
    private var updateAcknowledged = false
    @Published var selection = "Overview"
    @Published var report = ScanReport()
    @Published var root: URL?
    @Published var jobs: [ArchiveJob] = []
    @Published var busy = false {
        didSet {
            // A deadline that fired during any operation is rearmed once, after
            // the operation becomes idle. There is no retry/polling timer.
            if oldValue && !busy { scheduleRecommendations() }
        }
    }
    @Published var externalOperation: String?
    @Published var message = "Choose a folder to begin. Your files stay in place."
    @Published var errorMessage: String?
    @Published var connected = false
    @Published var authorizationChecked = false
    @Published var refreshFailure: String?
    @Published var refreshPhase: String?
    private var authorizationRefreshInProgress = false
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
    @Published var remoteRestoreRequests: [BrainArchiveRestoreRequest] = []
    @Published var folderHealth: [UUID: FolderArchiveHealthReport] = [:]
    @Published var recoveredFolderRecords: [RecoveredFolderSummary] = []
    @Published var recoveredFolderCount = 0
    @Published var recoveredFolderOffset = 0
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
    @Published var approvedFolders: [URL] = []
    @Published var transferPolicy = TransferPolicy() { didSet { saveProductSettings() } }
    @Published var recommendationRules = RecommendationRules() { didSet { saveProductSettings() } }
    @Published var recommendationSchedule = RecommendationSchedule() { didSet { saveProductSettings() } }
    @Published var recommendations: [SpaceRecommendation] = []
    @Published var excludedRecommendationIDs: Set<String> = []
    @Published var activities: [StorageActivity] = []
    @Published var activityCount = 0
    @Published var activityOffset = 0
    @Published var recoveryFiles: [ArchiveJob] = []
    @Published var loginStatus = "Not checked"
    @Published var loginEnabled = false
    @Published var recoveryFileCount = 0
    @Published var recoveryFileOffset = 0
    @Published var folderRecoveryRecords: [FolderRecoveryRecord] = []
    @Published var folderRecoveryCount = 0
    @Published var folderRecoveryOffset = 0
    @Published var recoveryOffset = 0
    @Published var showOnboarding = false
    @Published var showCommands = false
    private var settingsLoaded = false
    private var environmentMonitor: SystemTransferEnvironment?
    private var scheduledTask: Task<Void, Never>?
    private var ledger: ActivityLedger?
    @Published var lowDiskNotificationsEnabled = false
    @Published var notificationStatus = "Notifications are off. In-app storage status remains available."
    var storageIsLow: Bool { totalBytes > 0 && freeBytes < max(10_000_000_000, totalBytes / 20) }
    func enableLowDiskNotifications() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                lowDiskNotificationsEnabled = granted; UserDefaults.standard.set(granted, forKey: "lowDiskNotificationsEnabled")
                notificationStatus = granted ? "Low-storage notifications enabled. At most one per day while CloudNest is open." : "Notifications were not authorized. Change notification permissions in System Settings if needed."
            } catch { notificationStatus = "Notification permission could not be read. In-app warnings remain available." }
        }
    }
    func disableLowDiskNotifications() { lowDiskNotificationsEnabled = false; UserDefaults.standard.set(false, forKey: "lowDiskNotificationsEnabled"); notificationStatus = "Notifications are off." }
    private func notifyIfStorageLow() async {
        guard lowDiskNotificationsEnabled, storageIsLow else { return }
        let last = UserDefaults.standard.object(forKey: "lastLowDiskNotification") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86_400 else { return }
        let content = UNMutableNotificationContent(); content.title = "CloudNest: storage is running low"
        content.body = "Review Free Up Space recommendations from your approved folders. Nothing will be deleted automatically."
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cloudnest-low-storage", content: content, trigger: nil))
            UserDefaults.standard.set(Date(), forKey: "lastLowDiskNotification")
        } catch { notificationStatus = "The low-storage notification could not be delivered. Check notification permissions." }
    }
    var selectedRecommendations: [SpaceRecommendation] { Array(recommendations.prefix(200)).filter { !excludedRecommendationIDs.contains($0.id) } }
    var recommendedAllocation: Int64 { selectedRecommendations.reduce(0) { $0 + $1.candidate.allocatedBytes } }
    private func makeRemote() throws -> any ArchiveRemote {
        if transferPolicy.enabled {
            if environmentMonitor == nil { environmentMonitor = SystemTransferEnvironment() }
            let monitor = environmentMonitor!
            return try PolicyArchiveRemote(remote: drive, policy: transferPolicy, environment: { try await monitor.current() })
        }
        environmentMonitor = nil
        return drive
    }
    private func loadProductSettings() throws {
        guard !settingsLoaded else { return }
        transferPolicy = try CloudNestPreferences.transferPolicy(from: .standard)
        recommendationRules = try CloudNestPreferences.recommendationRules(from: .standard)
        recommendationSchedule = try CloudNestPreferences.recommendationSchedule(from: .standard)
        approvedFolders = (UserDefaults.standard.stringArray(forKey: "approvedFolders") ?? []).map { URL(fileURLWithPath: $0) }
        showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingCompleted")
        lowDiskNotificationsEnabled = UserDefaults.standard.bool(forKey: "lowDiskNotificationsEnabled")
        if lowDiskNotificationsEnabled { notificationStatus = "Low-storage notifications enabled. Delivery follows macOS notification permissions." }
        settingsLoaded = true; scheduleRecommendations()
    }
    private func saveProductSettings() {
        guard settingsLoaded else { return }
        do {
            try CloudNestPreferences.save(transferPolicy, key: "transferPolicy", to: .standard)
            try CloudNestPreferences.save(recommendationRules, key: "recommendationRules", to: .standard)
            try CloudNestPreferences.save(recommendationSchedule, key: "recommendationSchedule", to: .standard)
            if !busy, let catalog { coordinator = try makeCoordinator(catalog); folderCoordinator = try makeFolderCoordinator(catalog) }
            scheduleRecommendations()
        } catch { errorMessage = error.localizedDescription }
    }
    func finishOnboarding() { UserDefaults.standard.set(true, forKey: "onboardingCompleted"); showOnboarding = false }
    func addApprovedFolder() { chooseAndScan() }
    func forgetApprovedFolder(_ url: URL) {
        approvedFolders.removeAll { $0 == url }; UserDefaults.standard.set(approvedFolders.map(\.path), forKey: "approvedFolders")
        if root == url { watcher = nil; root = nil; report = ScanReport(); recommendations = [] }
        scheduleRecommendations()
    }
    private func approveFolder(_ url: URL) -> Bool {
        do { try FileSafety(protectedRoots: protectedFolders).validate(url, root: url) }
        catch { errorMessage = error.localizedDescription; return false }
        if !approvedFolders.contains(url) { approvedFolders.append(url); UserDefaults.standard.set(approvedFolders.map(\.path), forKey: "approvedFolders") }
        return true
    }
    func refreshActivities() async {
        do { activities = try await ledger?.events(limit: 50, offset: activityOffset) ?? []; activityCount = try await ledger?.count() ?? 0 }
        catch { errorMessage = error.localizedDescription }
    }
    func activityPage(_ direction: Int) { activityOffset = max(0, activityOffset + direction * 50); Task { await refreshActivities() } }
    private func record(_ event: StorageActivity, deduplicationKey: String? = nil) async {
        do { try await ledger?.append(event, deduplicationKey: deduplicationKey); await refreshActivities() }
        catch { errorMessage = "Activity history could not be updated. Review the archive catalog for durable transfer state." }
    }
    private func scheduleRecommendations() {
        scheduledTask?.cancel(); scheduledTask = nil
        guard recommendationSchedule.enabled, !approvedFolders.isEmpty else { return }
        let next = recommendationSchedule.isDue() ? Date().addingTimeInterval(3) : recommendationSchedule.nextDue()!
        scheduledTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)), tolerance: .seconds(30)); self?.runDueRecommendationScan() }
            catch { /* Settings changes cancel the single scheduled wakeup. */ }
        }
    }
    func runDueRecommendationScan() {
        guard recommendationSchedule.isDue(), !busy else { return }
        scanApprovedFolders(scheduled: true)
    }
    func scanApprovedFolders(scheduled: Bool = false) {
        guard !busy, !approvedFolders.isEmpty else { if approvedFolders.isEmpty { chooseAndScan() }; return }
        let folders = SpaceRescue.nonoverlappingRoots(approvedFolders), safety = FileSafety(protectedRoots: protectedFolders), rules = recommendationRules
        let bytes = Int64(min(1_000_000_000, max(0, minimumMB))) * 1_000_000, age = min(36_500, max(0, minimumAgeDays))
        runTask("Analyzing your approved folders for space recommendations…", cancellable: true, successMessage: nil) {
            let scan = Task.detached(priority: .utility) {
                var combined = ScanReport()
                for folder in folders {
                    guard combined.candidates.count < 10_000 else { combined.truncated = true; break }
                    let report = try FileScanner(safety: safety).scan(root: folder, minimumBytes: bytes, minimumAgeDays: age, limit: 10_000 - combined.candidates.count)
                    combined = SpaceRescue.merge([combined, report])
                }
                return rules.filter(combined)
            }
            let result = try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
            await MainActor.run {
                self.report = result; self.recommendations = SpaceRescue.rank(result); self.excludedRecommendationIDs = []; self.selection = "Free Up Space"
                self.message = "\(result.candidates.count) ranked candidates · allocation estimates only; no files changed\(result.truncated ? " · Scan limit reached" : "")"
                if self.recommendationSchedule.enabled { self.recommendationSchedule.lastCompleted = Date() }
            }
            await self.record(StorageActivity(kind: .scanned, title: scheduled ? "Scheduled recommendation scan" : "Free Up Space analysis", detail: "\(result.candidates.count) matches across \(folders.count) approved folders"))
        }
    }
    func archiveSelectedRecommendations() {
        let selected = selectedRecommendations
        guard let coordinator, !selected.isEmpty, !busy else { return }
        let alert = NSAlert(); alert.messageText = "Archive \(selected.count) selected files?"
        alert.informativeText = "Allocation estimate: \(format(recommendedAllocation)). Uploads retain every original. Cleanup is separately approved after verification. The scan does not prove inactivity or guaranteed SSD savings."
        alert.addButton(withTitle: "Archive selected"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let approved = approvedFolders
        runTask("Archiving selected recommendations…", cancellable: true) {
            for item in selected {
                try Task.checkCancellation()
                guard let root = approved.filter({ FileSafety.contains($0, item.candidate.url) }).max(by: { $0.path.count < $1.path.count }) else { throw NestError.unsafePath("file is outside approved folders") }
                let job = try await coordinator.enqueue(source: item.candidate.url, approvedRoot: root); try await coordinator.run(job.id)
            }
        }
    }
    func excludeRecommendation(_ id: String) { if excludedRecommendationIDs.contains(id) { excludedRecommendationIDs.remove(id) } else { excludedRecommendationIDs.insert(id) } }

    private var drive: DriveClient { DriveClient(oauth: oauth) }
    private func makeFolderCoordinator(_ db: Catalog) throws -> FolderArchiveCoordinator {
        FolderArchiveCoordinator(catalog: db, remote: try makeRemote(), safety: FileSafety(protectedRoots: protectedFolders), onFolderChanged: { [weak self] job in
            await self?.folderChanged(job)
        }, onFileChanged: { [weak self] job in
            await self?.jobChanged(job)
        })
    }
    private func folderChanged(_ job: FolderArchiveJob) async {
        if let index = folderJobs.firstIndex(where: { $0.id == job.id }) { folderJobs[index] = job }
        else { folderJobs.insert(job, at: 0) }
        if folderJobs.count > 100 { folderJobs.removeLast() }
        if job.state == .verified { await record(StorageActivity(kind: .folderVerified, title: job.source.lastPathComponent, jobID: job.id, bytes: job.totalBytes), deduplicationKey: "folder-verified-" + job.id.uuidString) }
        message = "Folder: \(job.source.lastPathComponent) · \(job.completedFiles) of \(job.totalFiles) files verified"
    }
    func openDrive(_ job: ArchiveJob, copy: Bool = false) {
        guard job.state == .uploaded || job.state == .verified,
              let id = job.remoteID, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let url = URL(string: "https://drive.google.com/file/d/" + id + "/view") else { return }
        if copy { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string); message = "Drive URL copied. Google access permissions still apply; no sharing permission was changed." }
        else { NSWorkspace.shared.open(url) }
    }
    func showOriginal(_ job: ArchiveJob) { NSWorkspace.shared.activateFileViewerSelecting([job.source]) }
    func reviewSelectedURL(_ url: URL, restore: Bool = false) {
        guard !busy else { errorMessage = "Finish or pause the current operation before reviewing another item."; return }
        guard url.isFileURL else { errorMessage = "Choose a local file URL."; return }
        if restore { restoreSelectedManifest(url); return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { errorMessage = "The selected item is unavailable."; return }
        if isDirectory.boolValue {
            let alert = NSAlert(); alert.messageText = "Review \(url.lastPathComponent) with CloudNest?"
            alert.informativeText = "Approve this folder for recommendation scans: \(url.path)\n\nNo upload or cleanup starts from this review. Protected and built-in exclusions still apply."
            alert.addButton(withTitle: "Approve & scan"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, approveFolder(url) else { return }; scan(url)
        } else {
            guard connected, let coordinator else { selection = "Settings"; errorMessage = "Connect Google Drive before archiving the selected file."; return }
            let alert = NSAlert(); alert.messageText = "Archive \(url.lastPathComponent)?"
            alert.informativeText = "CloudNest will upload only this selected file, verify its recovery manifest and retain the original. Its parent folder is not added to scheduled scans."
            alert.addButton(withTitle: "Upload & verify"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            runTask("Archiving the selected file…", cancellable: true) { let job = try await coordinator.enqueue(source: url, approvedRoot: url.deletingLastPathComponent()); try await coordinator.run(job.id) }
        }
    }
    func performCommand(_ command: String) {
        switch command {
        case "Scan a folder…": if !busy { chooseAndScan() }
        case "Archive a folder…": if !busy, connected { archiveFolder() } else { message = "Connect Google Drive and finish active work before archiving." }
        case "Restore from manifest…": if !busy, connected { restoreFromManifest() } else { message = "Connect Google Drive and finish active work before restoring." }
        case "Setup guide": showOnboarding = true
        case "Settings & Security": selection = "Settings"
        default: selection = command
        }
    }
    func refreshRecovery() async {
        do {
            recoveryFiles = try await catalog?.recoveryJobs(limit: 100, offset: recoveryFileOffset) ?? []
            recoveryFileCount = try await catalog?.recoveryJobCount() ?? 0
            folderRecoveryRecords = try await catalog?.folderRecoveryRecords(limit: 100, offset: folderRecoveryOffset) ?? []
            folderRecoveryCount = try await catalog?.folderRecoveryRecordCount() ?? 0
        } catch { errorMessage = error.localizedDescription }
    }
    var canRegisterLoginItem: Bool { let path = Bundle.main.bundlePath; return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") }
    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status; loginEnabled = status == .enabled
        switch status { case .enabled: loginStatus = "Enabled in macOS"; case .requiresApproval: loginStatus = "Awaiting approval in macOS Login Items"; case .notRegistered: loginStatus = "Disabled"; case .notFound: loginStatus = "Install CloudNest in Applications first"; @unknown default: loginStatus = "Unknown macOS status" }
    }
    func setLoginItem(_ enabled: Bool) {
        guard !busy else { return }
        do { if enabled { guard canRegisterLoginItem else { throw NestError.unsafePath("Install CloudNest in Applications before registering login startup") }; try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; refreshLoginStatus() }
        catch { errorMessage = error.localizedDescription; refreshLoginStatus() }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func recoveryFilePage(_ direction: Int) { recoveryFileOffset = max(0, recoveryFileOffset + direction * 100); Task { await refreshRecovery() } }
    func folderRecoveryPage(_ direction: Int) { folderRecoveryOffset = max(0, folderRecoveryOffset + direction * 100); Task { await refreshRecovery() } }
    func revealFolderRecovery(_ record: FolderRecoveryRecord) { NSWorkspace.shared.activateFileViewerSelecting([record.recoveryLocation]) }
    func reviewCapsuleArchive(_ folder: URL) {
        guard let folderCoordinator, !busy, connected else { errorMessage = "Connect Google Drive and finish active work before archiving a generated backup."; return }
        let alert = NSAlert(); alert.messageText = "Archive this generated backup to Drive?"
        alert.informativeText = "\(folder.path)\n\nCloudNest inventories and uploads only this generated folder, then verifies every member and its portable manifest. Original repositories, Docker images and local copies remain in place. Cleanup always requires separate approval."
        alert.addButton(withTitle: "Archive & verify backup"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        selection = "Archive Library"
        runTask("Archiving the reviewed generated backup…", cancellable: true) { let job = try await folderCoordinator.enqueue(source: folder, approvedRoot: folder); try await folderCoordinator.run(job.id) }
    }
    func recoverFolderCatalog() {
        guard let catalog else { return }
        runTask("Recovering verified folder groups from Drive…", cancellable: true, successMessage: nil) {
            let result = try await self.drive.recoverFolderCatalog(into: catalog)
            await MainActor.run { self.message = "Folder recovery: \(result.imported) imported · \(result.existing) existing · \(result.rejected) rejected\(result.truncated ? " · budget reached" : "")" }
        }
    }
    func recoveredFolderPage(_ direction: Int) { recoveredFolderOffset = max(0, recoveredFolderOffset + direction * 30); Task { await searchLibrary(reset: false) } }
    func restoreRecoveredFolder(_ record: RecoveredFolderSummary) {
        guard let catalog, let folderCoordinator else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Restore folder here"
        panel.message = "Restore \(record.folderName) into a new root. Existing items are not overwritten."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        runTask("Restoring a recovered folder group…", cancellable: true) {
            let full = try await catalog.recoveredFolder(record.id)
            _ = try await folderCoordinator.restore(manifest: full.manifest, destination: destination)
            await self.record(StorageActivity(kind: .restored, title: record.folderName, detail: "Recovered portable folder manifest", jobID: record.id, bytes: record.totalBytes))
        }
    }
    func checkFolderHealth(_ job: FolderArchiveJob) {
        guard let folderCoordinator else { return }
        runTask("Checking the complete cloud folder archive…", cancellable: true) {
            let result = await folderCoordinator.health(job.id)
            await MainActor.run { self.folderHealth[job.id] = result }
        }
    }
    func stageFolderRecovery(_ job: FolderArchiveJob) {
        guard let folderCoordinator else { return }
        let alert = NSAlert(); alert.messageText = "Move this entire folder into managed recovery?"
        alert.informativeText = "\(job.source.path)\n\nCloudNest rechecks every file, the root manifest and portable metadata, then moves this folder into private recovery on the same volume. This does not free space. Unsupported metadata blocks the move."
        alert.addButton(withTitle: "Verify & move folder"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runTask("Verifying before retaining the complete folder…", cancellable: true) {
            try await folderCoordinator.moveToRecovery(job.id)
            await self.record(StorageActivity(kind: .recoveryStaged, title: job.source.lastPathComponent, detail: "Whole-folder recovery; no bytes reclaimed", jobID: job.id, bytes: job.totalBytes))
        }
    }
    func putBackFolder(_ id: UUID, name: String) {
        guard let folderCoordinator else { return }
        runTask("Putting the retained folder back without overwrite…") {
            try await folderCoordinator.putBackOriginal(id)
            await self.record(StorageActivity(kind: .putBack, title: name, jobID: id))
        }
    }
    func removeFolderRecovery(_ id: UUID, name: String, bytes: Int64) {
        guard let folderCoordinator else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Permanently remove this managed folder copy?"
        alert.informativeText = "\(name) · \(format(bytes)) retained\n\nAfter fresh cloud and local verification, CloudNest removes only manifested members. Unexpected or changed data stops cleanup. This cannot be undone locally. The verified cloud archive remains restorable. Interrupted cleanup requires another approval."
        alert.addButton(withTitle: "Verify & permanently remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runTask("Reverifying and removing managed folder members…", cancellable: true) {
            try await folderCoordinator.permanentlyRemoveRecovery(id)
            let result = try await folderCoordinator.job(id)
            await self.record(StorageActivity(kind: .removed, title: name, jobID: id, bytes: bytes, observedFreeBytes: result.recovery?.observedFreeSpaceIncrease ?? 0))
        }
    }
    private func publicationReview(name: String, action: @escaping @Sendable (String, BrainArchiveVisibility, URL) async throws -> Void) {
        guard !busy, connected else { return }; busy = true; message = "Loading the Brain recipient for metadata review…"
        Task {
            do {
                let origin = try await BrainArchiveCatalog().configuredOrigin()
                let alert = NSAlert(); alert.messageText = "Publish archive details to your Brain?"
                alert.informativeText = "\(name)\nDestination: \(origin.absoluteString)\n\nSends the name, size, checksum, Drive IDs, health-check time and last reported local state. Full paths and file contents are excluded. Google Drive authorization still controls download access."
                let project = NSTextField(string: "cloudnest"); project.placeholderString = "Project ID"
                let share = NSButton(checkboxWithTitle: "Allow scoped AI clients in this project to read these details", target: nil, action: nil)
                let stack = NSStackView(views: [NSTextField(labelWithString: "Project ID"), project, share]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.frame = NSRect(x: 0, y: 0, width: 430, height: 95); project.widthAnchor.constraint(equalToConstant: 430).isActive = true
                alert.accessoryView = stack; alert.addButton(withTitle: "Verify & publish details"); alert.addButton(withTitle: "Cancel")
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { throw NestError.unsafePath("Open the CloudNest window to review this publication") }
                message = "Review the Brain recipient, project and metadata visibility."
                let response = await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { result in continuation.resume(returning: result) }
                }
                busy = false
                guard response == .alertFirstButtonReturn else { message = "Archive publication cancelled. No metadata was sent."; return }
                let projectID = project.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard projectID.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else { throw NestError.unsafePath("Use a project ID containing letters, numbers, periods, underscores or hyphens") }
                let visibility: BrainArchiveVisibility = share.state == .on ? .approved : .private
                runTask("Checking cloud health before publishing reviewed metadata…", cancellable: true, successMessage: "Archive details published. Their local state is a timestamped report; Drive access remains authenticated.") { try await action(projectID, visibility, origin) }
            } catch { busy = false; message = "Archive publication review could not start."; errorMessage = error.localizedDescription }
        }
    }
    func publishFileDetails(_ job: ArchiveJob) {
        guard let catalog else { return }
        publicationReview(name: job.source.lastPathComponent) { project, visibility, approvedOrigin in
            let current = try await catalog.job(job.id)
            let report = await ArchiveHealthChecker(remote: self.drive).check(current)
            let publication = try BrainArchivePublication.verifiedFile(current, health: report)
            _ = try await BrainArchiveCatalog(expectedOrigin: approvedOrigin).publish(project: project, visibility: visibility, archives: [publication])
        }
    }
    func publishFolderDetails(_ job: FolderArchiveJob) {
        guard let folderCoordinator else { return }
        publicationReview(name: job.source.lastPathComponent) { project, visibility, approvedOrigin in
            let report = await folderCoordinator.health(job.id)
            let full = try await folderCoordinator.job(job.id)
            let publication = try BrainArchivePublication.verifiedFolder(full, health: report)
            _ = try await BrainArchiveCatalog(expectedOrigin: approvedOrigin).publish(project: project, visibility: visibility, archives: [publication])
        }
    }
    func refreshRemoteRestoreRequests() {
        runTask("Reading the owner restore-request queue…", successMessage: nil) {
            let requests = try await BrainArchiveCatalog().pendingRestoreRequests()
            await MainActor.run { self.remoteRestoreRequests = requests; self.message = "\(requests.count) pending remote restore requests. Each requires local review and a destination." }
        }
    }
    func dismissRemoteRestore(_ request: BrainArchiveRestoreRequest) {
        runTask("Dismissing this queue request…", successMessage: nil) {
            _ = try await BrainArchiveCatalog().acknowledgeRestoreRequest(request.id, status: .dismissed)
            await MainActor.run { self.remoteRestoreRequests.removeAll { $0.id == request.id }; self.message = "Restore request dismissed. Archive data is retained." }
        }
    }
    func reviewRemoteRestore(_ request: BrainArchiveRestoreRequest) {
        guard let catalog, let coordinator, let folderCoordinator, connected, !busy else { return }
        busy = true; message = "Matching the request to a verified local recovery manifest…"
        Task {
            do {
                let published = try await BrainArchiveCatalog().read(request.archiveId)
                let manifest: PortableManifest
                if published.kind == .file {
                    if let job = try? await catalog.job(request.archiveId), job.state == .verified, let remoteID = job.remoteID, job.manifestID == published.manifestFileId, remoteID == published.driveFileId, job.snapshot.sha256 == published.sha256 {
                        manifest = .file(ArchiveManifest(job: job, driveFileID: remoteID))
                    } else {
                        let recovered = try await catalog.recoveredArchives(query: request.archiveId.uuidString, limit: 20)
                        guard let record = recovered.first(where: { $0.id == request.archiveId && $0.manifestID == published.manifestFileId && $0.manifest.driveFileID == published.driveFileId && $0.manifest.sha256 == published.sha256 }) else { throw NestError.unsafePath("No matching verified recovery manifest is available locally. Rebuild the file catalog from Drive and review this request again") }
                        manifest = .file(record.manifest)
                    }
                } else {
                    if let job = try? await folderCoordinator.job(request.archiveId), job.state == .verified, job.remoteManifestID == published.manifestFileId, let root = job.manifest { manifest = .folder(root) }
                    else {
                        guard let record = try? await catalog.recoveredFolder(request.archiveId), record.manifestID == published.manifestFileId else { throw NestError.unsafePath("No matching folder recovery manifest is available locally. Rebuild folder groups from Drive, then review again") }
                        manifest = .folder(record.manifest)
                    }
                }
                let localName: String
                switch manifest {
                case .file(let file): try published.validateRestoreManifest(file); localName = file.fileName
                case .folder(let folder): try published.validateRestoreManifest(folder); localName = folder.folderName
                }
                busy = false
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Restore requested archive here"
                panel.message = "Restore \(localName) from its verified local manifest. The remote request supplies no destination. Existing items are never overwritten."
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                runTask("Restoring and verifying the reviewed remote request…", cancellable: true, successMessage: nil) {
                    switch manifest {
                    case .file(let file): _ = try await coordinator.restore(manifest: file, destination: destination)
                    case .folder(let folder): _ = try await folderCoordinator.restore(manifest: folder, destination: destination)
                    }
                    await self.record(StorageActivity(kind: .restored, title: localName, detail: "Owner request reviewed locally", jobID: request.archiveId, bytes: published.bytes))
                    do {
                        _ = try await BrainArchiveCatalog().acknowledgeRestoreRequest(request.id, status: .completed)
                        await MainActor.run { self.remoteRestoreRequests.removeAll { $0.id == request.id }; self.message = "Requested archive restored and verified; remote queue acknowledged." }
                    } catch {
                        await MainActor.run { self.message = "Restore succeeded locally. Queue acknowledgment is still pending."; self.errorMessage = "The archive was restored and verified, but its remote acknowledgment did not save. Keep the verified local copy; review and dismiss the pending request separately." }
                    }
                }
            } catch { busy = false; errorMessage = error.localizedDescription }
        }
    }
    func cancelOperation() {
        guard canCancel else { return }
        canCancel = false
        message = "Pausing safely… Verified uploads and originals will be retained."
        activeTask?.cancel()
    }
    func searchLibrary(reset: Bool = true) async {
        if reset { libraryOffset = 0; recoveredOffset = 0; recoveredFolderOffset = 0 }
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
            recoveredFolderRecords = try await catalog?.recoveredFolders(query: query, limit: 30, offset: recoveredFolderOffset) ?? []
            recoveredFolderCount = try await catalog?.recoveredFolderCount(query: query) ?? 0
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
            await self.record(StorageActivity(kind: .restored, title: record.manifest.fileName, jobID: record.id, bytes: record.manifest.size))
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
    private func makeCoordinator(_ db: Catalog) throws -> ArchiveCoordinator {
        ArchiveCoordinator(catalog: db, remote: try makeRemote(), safety: FileSafety(protectedRoots: protectedFolders), onJobChanged: { [weak self] job in
            await self?.jobChanged(job)
        })
    }
    private func jobChanged(_ job: ArchiveJob) async {
        if job.state == .verified {
            await record(StorageActivity(kind: .archiveVerified, title: job.source.lastPathComponent, jobID: job.id, bytes: job.snapshot.identity.size), deduplicationKey: "verified-" + job.id.uuidString)
        }
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
    private func refreshDriveAuthorization() async {
        guard !authorizationRefreshInProgress else { return }
        authorizationRefreshInProgress = true
        defer { authorizationRefreshInProgress = false }
        connected = await oauth.isConnected()
        authorizationChecked = true
        if !connected { quota = nil }
    }
    func refresh() async {
        async let authorization: Void = refreshDriveAuthorization()
        defer { refreshPhase = nil }
        do {
            refreshPhase = "Loading local settings…"
            try loadProductSettings()
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            totalBytes = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
            freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            if catalog == nil {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CloudNest", isDirectory: true)
                refreshPhase = "Opening the local archive catalog…"
                let db = try Catalog(directory: directory)
                catalog = db; coordinator = try makeCoordinator(db); folderCoordinator = try makeFolderCoordinator(db)
                ledger = try ActivityLedger(directory: directory)
                refreshPhase = "Checking retained recovery records…"
                try await coordinator?.reconcileRecovery()
                try await folderCoordinator?.reconcileRecovery()
            }
            refreshPhase = "Reading saved archive status…"
            jobs = try await catalog?.jobs() ?? []
            try await refreshTotals()
            folderJobs = try await folderCoordinator?.jobs(limit: 100) ?? []
            await searchLibrary(reset: false)
            refreshPhase = "Refreshing activity and recovery…"
            await refreshActivities(); await refreshRecovery()
            refreshFailure = nil
            if !updateAcknowledged {
                try ReleaseUpdateInstaller.acknowledge(arguments: CommandLine.arguments, currentApp: Bundle.main.bundleURL)
                updateAcknowledged = true
            }
            await notifyIfStorageLow()
        } catch is CancellationError {
            refreshFailure = "The local status refresh was interrupted. Existing archives are retained; retry to read their latest status."
        } catch {
            refreshFailure = error.localizedDescription
            message = "Local archive status could not be refreshed. Review the message above; originals are retained."
        }
        await authorization
    }
    func chooseAndScan() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Scan folder"; panel.message = "Only this folder is approved. Repositories, databases and cloud folders are excluded."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard approveFolder(url) else { return }; scan(url)
    }
    func scan(_ url: URL) {
        guard !busy else { return }
        root = url; report = ScanReport(); duplicates = []; watcher = nil; selection = "Storage"; busy = true; canCancel = true
        message = "Scanning \(url.lastPathComponent)…"; scanIsStale = false; scanProgress = nil
        let request = UUID(); activeScanID = request
        let rules = recommendationRules
        let safety = FileSafety(protectedRoots: protectedFolders), bytes = Int64(min(1_000_000_000, max(0, minimumMB))) * 1_000_000, age = min(36_500, max(0, minimumAgeDays))
        activeTask = Task {
            do {
                let scan = Task.detached(priority: .utility) { [model = self] in
                    try FileScanner(safety: safety).scan(root: url, minimumBytes: bytes, minimumAgeDays: age, onProgress: { progress in
                        Task { @MainActor [weak model] in if model?.activeScanID == request { model?.scanProgress = progress } }
                    })
                }
                report = rules.filter(try await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() }))
                recommendations = SpaceRescue.rank(report); excludedRecommendationIDs = []
                try Task.checkCancellation()
                message = "\(report.candidates.count) files matched · \(report.excluded) excluded\(report.truncated ? " · Scan limit reached" : "")"
                await record(StorageActivity(kind: .scanned, title: "Folder scan", detail: "\(report.candidates.count) matches in \(url.lastPathComponent)"))
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
        if let catalog { do { coordinator = try makeCoordinator(catalog); folderCoordinator = try makeFolderCoordinator(catalog) } catch { errorMessage = error.localizedDescription } }
        report = ScanReport(); duplicates = []
    }
    func recoverOriginal(_ job: ArchiveJob) {
        guard let coordinator else { return }
        runTask("Putting back \(job.source.lastPathComponent)…") { try await coordinator.putBackOriginal(job.id); await self.record(StorageActivity(kind: .putBack, title: job.source.lastPathComponent, jobID: job.id)) }
    }
    func retainForCleanup(_ job: ArchiveJob) {
        guard let coordinator else { return }
        let alert = NSAlert(); alert.messageText = "Move this original into CloudNest recovery?"
        alert.informativeText = "\(job.source.path)\n\nCloudNest will reverify Drive and the source, then move exactly this file into a private recovery folder on the same volume. This step does not free space. You can put it back."
        alert.addButton(withTitle: "Move to recovery"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runTask("Reverifying archive before moving the original…") { try await coordinator.moveToRecovery(job.id); await self.record(StorageActivity(kind: .recoveryStaged, title: job.source.lastPathComponent, jobID: job.id, bytes: job.snapshot.identity.size)) }
    }
    func removeRecovery(_ job: ArchiveJob) {
        guard let coordinator else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Permanently remove this managed recovery copy?"
        alert.informativeText = "\(job.source.lastPathComponent) · \(format(job.recovery?.retainedBytes ?? 0))\n\nThis cannot be undone locally. CloudNest will reverify the cloud file, recovery manifest and retained data first. The cloud archive will remain available for restore. APFS snapshots may retain blocks. No other file or Trash item is affected."
        alert.addButton(withTitle: "Permanently remove copy"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runTask("Reverifying the managed copy before removal…") { try await coordinator.permanentlyRemoveRecovery(job.id)
            let updated = try await self.catalog?.job(job.id)
            await self.record(StorageActivity(kind: .removed, title: job.source.lastPathComponent, jobID: job.id, observedFreeBytes: updated?.recovery?.observedFreeSpaceIncrease ?? 0))
        }
    }
    private let foregroundGate = ForegroundOperationGate()
    func acquireExternalOperation(section: String) -> (@MainActor () -> Void)? {
        guard !busy, let owner = foregroundGate.acquire() else { return nil }
        externalOperation = section; busy = true
        return { [weak self] in
            guard let self, self.foregroundGate.release(owner) else { return }
            self.externalOperation = nil; self.busy = false
            Task { await self.refresh() }
        }
    }
    @Published var projectBrainConfigured = false
    func refreshProjectBrain() async { projectBrainConfigured = await ProjectCardBrainWriter.isConfigured() }
    func archiveProjectSnapshot(_ capsule: ProjectCapsuleResult) async throws -> FolderArchiveJob {
        guard connected, let folderCoordinator else { throw NestError.unsafePath("connect Google Drive first") }
        try await drive.requirePrivateStorageDestination()
        let key = "projectSnapshotArchive-" + capsule.manifest.id.uuidString
        let job: FolderArchiveJob
        if let saved = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: saved) {
            job = try await folderCoordinator.job(id)
            guard job.source.standardizedFileURL == capsule.directory.standardizedFileURL else { throw NestError.invalidManifest }
        } else {
            job = try await folderCoordinator.enqueue(source: capsule.directory, approvedRoot: capsule.directory)
            UserDefaults.standard.set(job.id.uuidString, forKey: key)
        }
        if job.state != .verified { try await folderCoordinator.run(job.id) }
        let complete = try await folderCoordinator.job(job.id)
        guard complete.state == .verified else { throw NestError.verificationFailed }
        await refresh()
        return complete
    }
    func saveProjectCard(_ card: ProjectMemoryCard) async throws { guard let catalog else { throw NestError.notConfigured }; try await ProjectCardBrainWriter.save(card, catalog: catalog); message = "Project Memory Card saved privately. The original repository remains protected." }
    func archiveParkedModel(_ preview: ModelParkingPreview) async throws {
        guard connected, let coordinator, let folderCoordinator else { throw NestError.unsafePath("connect Google Drive first") }
        let safety = FileSafety(protectedRoots: protectedFolders)
        let inspection = Task.detached(priority: .utility) { try ModelParking.revalidate(preview, safety: safety) }
        try await withTaskCancellationHandler(operation: { try await inspection.value }, onCancel: { inspection.cancel() })
        message = "Archiving and verifying the selected model…"
        if preview.isDirectory {
            let job = try await folderCoordinator.enqueue(source: preview.source, approvedRoot: preview.approvedRoot, purpose: .modelParking)
            try await folderCoordinator.run(job.id)
            let complete = try await folderCoordinator.job(job.id)
            guard complete.state == .verified else { throw NestError.verificationFailed }
            await record(StorageActivity(kind: .folderVerified, title: preview.source.lastPathComponent, jobID: job.id, bytes: preview.logicalBytes))
        } else {
            let job = try await coordinator.enqueue(source: preview.source, approvedRoot: preview.approvedRoot, purpose: .modelParking)
            try await coordinator.run(job.id)
            guard try await catalog?.job(job.id).state == .verified else { throw NestError.verificationFailed }
            await record(StorageActivity(kind: .archiveVerified, title: preview.source.lastPathComponent, jobID: job.id, bytes: preview.logicalBytes))
        }
        message = "Model archive verified. Originals remain local; restore and separate cleanup are in Archive Library."
        await refresh()
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
            await self.record(StorageActivity(kind: .restored, title: job.source.lastPathComponent, jobID: job.id, bytes: job.snapshot.identity.size))
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
    func restoreFolder(_ job: FolderArchiveJob) { restoreManagedFolder(job.id) }
    func restoreManagedFolder(_ id: UUID) {
        guard let folderCoordinator, !busy else { return }
        busy = true; message = "Reading the portable folder manifest…"
        Task {
            do {
                let url = await folderCoordinator.manifestURL(for: id)
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
        runTask("Restoring and verifying the complete folder…", cancellable: true) {
            _ = try await folderCoordinator.restore(manifest: manifest, destination: destination)
            await self.record(StorageActivity(kind: .restored, title: manifest.folderName, jobID: manifest.id, bytes: manifest.files.reduce(0) { $0 + $1.manifest.size }))
        }
    }
    func revealFolderManifest(_ job: FolderArchiveJob) {
        guard let folderCoordinator else { return }
        Task {
            let url = await folderCoordinator.manifestURL(for: job.id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    func restoreFromManifest() {
        guard coordinator != nil, !busy else { return }
        let manifestPanel = NSOpenPanel(); manifestPanel.canChooseDirectories = false; manifestPanel.canChooseFiles = true
        manifestPanel.prompt = "Read recovery manifest"; manifestPanel.message = "Choose a CloudNest file or folder JSON recovery manifest. This works without an original catalog."
        guard manifestPanel.runModal() == .OK, let url = manifestPanel.url else { return }
        restoreSelectedManifest(url)
    }
    private func restoreSelectedManifest(_ url: URL) {
        guard let coordinator, connected, !busy else { errorMessage = "Connect Drive and finish current work before restoring."; return }
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
                    runTask("Restoring from a portable recovery manifest…", cancellable: true) {
                        _ = try await coordinator.restore(manifest: file, destination: destination)
                        await self.record(StorageActivity(kind: .restored, title: file.fileName, jobID: file.jobID, bytes: file.size))
                    }
                }
            } catch is CancellationError {
                busy = false; canCancel = false; activeTask = nil; message = "Manifest read cancelled. No files were changed."
            } catch { busy = false; canCancel = false; activeTask = nil; errorMessage = error.localizedDescription }
        }
    }
    func importOAuth() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "Select the original dedicated Storage Desktop OAuth JSON. Reimporting disconnects the current grant. Keep this client separate from Brain; a different Google app may not access existing archives."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if connected {
            let review = NSAlert(); review.messageText = "Replace the Storage OAuth client?"
            review.informativeText = "Importing a valid client disconnects the current sign-in. A different Google project may be unable to access existing archives through drive.file. Keep your original Storage client available; the Brain client is separate. Invalid input leaves the current configuration intact."
            review.addButton(withTitle: "Import replacement"); review.addButton(withTitle: "Cancel")
            guard review.runModal() == .alertFirstButtonReturn else { return }
        }
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
            catch is CancellationError { message = "Paused safely. Originals are retained; use Resume to continue an upload."; await record(StorageActivity(kind: .paused, title: text)) }
            catch {
                if Task.isCancelled { message = "Paused safely. Originals are retained; use Resume to continue an upload." }
                else {
                    errorMessage = (error as? NestError)?.localizedDescription ?? (error as? DriveServiceError)?.localizedDescription ?? (error as? TransferPolicyError)?.localizedDescription ?? "The operation was interrupted. Review the queue and retry."
                    await record(StorageActivity(kind: .failed, title: text, detail: errorMessage ?? ""))
                }
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
                    Section("Workspace") {
                        Label("Overview", systemImage: "square.grid.2x2").tag("Overview")
                        Label("Storage", systemImage: "internaldrive").tag("Storage")
                        Label("Free Up Space", systemImage: "leaf").tag("Free Up Space")
                        Label("Smart Sweep", systemImage: "sparkle.magnifyingglass").tag("Smart Sweep")
                        Label("Model Parking", systemImage: "externaldrive.badge.icloud").tag("Model Parking")
                        Label("Archive Library", systemImage: "archivebox").tag("Archive Library")
                    }
                    Section("Intelligence") {
                        Label("AI Brain", systemImage: "brain").tag("AI Brain")
                        Label("Memory Universe", systemImage: "sparkles").tag("Memory Universe")
                        Label("Connections", systemImage: "point.3.connected.trianglepath.dotted").tag("Connections")
                        Label("Hibernate Project", systemImage: "moon.zzz").tag("Hibernate Project")
                        Label("Developer", systemImage: "chevron.left.forwardslash.chevron.right").tag("Developer")
                    }
                    Section("System") {
                        Label("Activity", systemImage: "clock").tag("Activity")
                        Label("Recovery Center", systemImage: "tray.and.arrow.down").tag("Recovery Center")
                        Label("Settings & Security", systemImage: "lock.shield").tag("Settings")
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Originals protected", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
                    Text("LOCAL BUILD").font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(.tertiary)
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
                if let failure = model.refreshFailure {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) { Text("Local status needs attention").font(.headline); Text(failure).font(.caption).textSelection(.enabled) }
                        Spacer(); Button("Retry status") { Task { await model.refresh() } }.disabled(model.busy)
                    }.padding(.horizontal, 30).padding(.vertical, 12).background(Color.orange.opacity(0.08))
                } else if let phase = model.refreshPhase {
                    HStack { ProgressView().controlSize(.mini); Text(phase).font(.caption); Spacer() }.padding(.horizontal, 30).padding(.vertical, 8)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.selection == "Overview" { overview }
                        else if model.selection == "Storage" { storage }
                        else if model.selection == "Archive Library" { archiveLibrary }
                        else if model.selection == "Free Up Space" { FreeSpaceView(model: model) }
                        else if model.selection == "Smart Sweep" { SmartSweepView(protectedRoots: model.protectedFolders, acquireOperation: { model.acquireExternalOperation(section: "Smart Sweep") }).disabled(model.busy && model.externalOperation != "Smart Sweep") }
                        else if model.selection == "Hibernate Project" { ProjectHibernationView(connected: model.connected, brainConnected: model.projectBrainConfigured, operationBusy: model.busy && model.externalOperation != "Hibernate Project", protectedFolders: model.protectedFolders, onArchive: model.archiveProjectSnapshot, onSaveCard: model.saveProjectCard, acquireOperation: { model.acquireExternalOperation(section: "Hibernate Project") }).task { await model.refreshProjectBrain() } }
                        else if model.selection == "Model Parking" { ModelParkingView(connected: model.connected, operationBusy: model.busy && model.externalOperation != "Model Parking", protectedFolders: model.protectedFolders, onArchive: model.archiveParkedModel, onOpenArchiveLibrary: { model.selection = "Archive Library" }, acquireOperation: { model.acquireExternalOperation(section: "Model Parking") }) }
                        else if model.selection == "Activity" { ActivityView(model: model) }
                        else if model.selection == "Recovery Center" { RecoveryCenterView(model: model) }
                        else if model.selection == "AI Brain" { NativeBrainView() }
                        else if model.selection == "Memory Universe" { BrainConsoleLauncher(section: "universe", title: "Memory Universe", configure: { model.selection = "AI Brain" }) }
                        else if model.selection == "Connections" { BrainConsoleLauncher(section: "connections", title: "Connections", configure: { model.selection = "AI Brain" }) }
                        else if model.selection == "Developer" { VStack(alignment: .leading, spacing: 32) { DeveloperView(protectedRoots: model.protectedFolders, archiveCapsule: model.reviewCapsuleArchive); Divider(); DockerBackupView(protectedRoots: model.protectedFolders, archiveBackup: model.reviewCapsuleArchive); Divider(); DatabaseBackupView(protectedRoots: model.protectedFolders, archiveBackup: model.reviewCapsuleArchive); Divider(); PostgresBackupView(protectedRoots: model.protectedFolders, archiveBackup: model.reviewCapsuleArchive) } }
                        else { settings; ProductSettingsView(model: model); ReleasePublisherSettingsView(acquireInstallation: { model.acquireExternalOperation(section: "Settings") }) }
                    }.padding(30)
                }
                Divider()
                HStack { Image(systemName: "shield.lefthalf.filled").foregroundStyle(accent); Text(model.message).lineLimit(2); Spacer(); Text("No background polling").foregroundStyle(.tertiary) }.font(.caption).padding(14)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            guard !model.busy, let item = providers.first else { return false }
            _ = item.loadObject(ofClass: NSURL.self) { value, _ in
                guard let url = value as? URL else { return }
                Task { @MainActor in model.reviewSelectedURL(url) }
            }
            return true
        }
        .sheet(isPresented: $model.showOnboarding) { WelcomeSetupView(model: model) }
        .sheet(isPresented: $model.showCommands) { CommandPaletteView(model: model) }
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
            if model.storageIsLow {
                panel {
                    Label("Storage is running low", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                    Text("Review candidates from your approved folders. Estimated allocation and measured free-space increases are shown separately.").foregroundStyle(.secondary)
                    Button("Free Up Space") { model.selection = "Free Up Space" }
                }
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
                    Button("Recover folder groups…", action: model.recoverFolderCatalog).disabled(model.busy || !model.connected)
                    Button("Restore from manifest…", action: model.restoreFromManifest).disabled(model.busy || !model.connected)
                    Button("Archive folder…", action: model.archiveFolder).buttonStyle(.borderedProminent).disabled(model.busy || !model.connected)
                }
            }
            if !model.folderJobs.isEmpty {
                panel {
                    Label("Folder archives · latest 100", systemImage: "folder.badge.checkmark").font(.headline)
                    Text("Folder cleanup verifies the complete archive and portable metadata, then requires two separate approvals. Legacy or unsupported metadata stays local.").font(.caption).foregroundStyle(.secondary)
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
                                    Button("Check health") { model.checkFolderHealth(job) }.disabled(model.busy || !model.connected)
                                    Button("Publish details…") { model.publishFolderDetails(job) }.disabled(model.busy || !model.connected || job.state != .verified)
                                    Button("Manifest") { model.revealFolderManifest(job) }.disabled(model.busy)
                                    Button("Restore folder…") { model.restoreFolder(job) }.disabled(model.busy || !model.connected)
                                } else { Button("Resume / verify") { model.resumeFolder(job) }.disabled(model.busy || !model.connected) }
                            }
                            if job.state != .verified && job.totalFiles > 0 { ProgressView(value: Double(job.completedFiles), total: Double(job.totalFiles)).accessibilityLabel("Verified files") }
                            if let recovery = job.recovery {
                                Text("Local folder: \(recovery.stage.rawValue) · \(model.format(recovery.retainedBytes)) retained").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    if recovery.canPutBack {
                                        Button("Put back folder") { model.putBackFolder(job.id, name: job.source.lastPathComponent) }.disabled(model.busy)
                                    }
                                    if recovery.stage == .retained || recovery.stage == .removing {
                                        Button("Remove managed folder…", role: .destructive) { model.removeFolderRecovery(job.id, name: job.source.lastPathComponent, bytes: recovery.retainedBytes) }.disabled(model.busy || !model.connected)
                                    }
                                }
                            } else if job.state == .verified {
                                Button("Reclaim folder…") { model.stageFolderRecovery(job) }.disabled(model.busy || !model.connected)
                            }
                            if let health = model.folderHealth[job.id] { Text(health.detail).font(.caption).foregroundStyle(health.status == .healthy ? .green : .orange) }

                        }.padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            if !model.recoveredFolderRecords.isEmpty {
                panel {
                    Label("Recovered folder groups", systemImage: "folder.badge.checkmark").font(.headline)
                    Text("These verified portable groups authorize restore only. They never authorize local cleanup.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recoveredFolderRecords) { record in
                        HStack { VStack(alignment: .leading, spacing: 5) { Text(record.folderName).font(.headline); Text("\(record.fileCount) files · \(model.format(record.totalBytes))").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Restore folder…") { model.restoreRecoveredFolder(record) }.disabled(model.busy || !model.connected) }; Divider()
                    }
                    HStack { Text("\(model.recoveredFolderCount) matching folder groups").font(.caption); Spacer(); Button("Previous groups") { model.recoveredFolderPage(-1) }.disabled(model.busy || model.recoveredFolderOffset == 0); Button("Next groups") { model.recoveredFolderPage(1) }.disabled(model.busy || model.recoveredFolderOffset + model.recoveredFolderRecords.count >= model.recoveredFolderCount) }
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
        .contextMenu {
            Button("Open in Google Drive") { model.openDrive(job) }.disabled(job.remoteID == nil || (job.state != .uploaded && job.state != .verified))
            Button("Copy Drive URL") { model.openDrive(job, copy: true) }.disabled(job.remoteID == nil || (job.state != .uploaded && job.state != .verified))
            Button("Show original in Finder") { model.showOriginal(job) }.disabled(!FileManager.default.fileExists(atPath: job.source.path))
            Button("Check cloud health") { model.checkHealth(job) }.disabled(model.busy || !model.connected || job.state != .verified)
            Button("Publish details to Brain…") { model.publishFileDetails(job) }.disabled(model.busy || !model.connected || job.state != .verified || job.folderArchiveID != nil)
        }
    }

    private var settings: some View {
        Group {
            Text("Your cloud. Your control.").font(.largeTitle.bold())
            panel {
                Label("Google Drive", systemImage: "externaldrive.badge.icloud").font(.headline)
                Text("Keep your dedicated Storage Desktop OAuth client and Google account stable so existing drive.file archives remain accessible. Brain uses a separate grant. Client configuration, credentials and upload sessions are stored in macOS Keychain.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Import OAuth JSON…", action: model.importOAuth)
                    Button("Sign in with Google", action: model.signIn).buttonStyle(.borderedProminent)
                    if model.connected { Button("Revoke access", role: .destructive, action: model.revoke) }
                }.disabled(model.busy).padding(.top, 8)
                Link("Google Cloud setup", destination: URL(string: "https://console.cloud.google.com/auth/clients")!).font(.caption)
            }
            panel {
                Label("Safety defaults", systemImage: "lock.shield").font(.headline)
                Text("Only approved folders are scanned. Scheduled recommendations are opt-in. One upload runs at a time. Rules never grant cleanup permission. Cleanup requires two separate approvals and fresh integrity checks. No symlinks, repositories, live databases, system folders, Photos libraries or cloud placeholders.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Label("Independent Brain", systemImage: "network").font(.headline)
                Text("Manage the independent cloud connection in AI Brain. Memory access is scoped per client; the browser console also provides history, export, recovery and the Memory Universe. Storage works independently.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open AI Brain") { model.selection = "AI Brain" }
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
