import SwiftUI
import AppKit
import CloudNestCore

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
            Text("CloudNest · Storage preview")
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
                catalog = db; coordinator = makeCoordinator(db)
                try await coordinator?.reconcileRecovery()
            }
            jobs = try await catalog?.jobs() ?? []
            try await refreshTotals()
            connected = await oauth.isConnected()
        } catch { errorMessage = error.localizedDescription }
    }
    func chooseAndScan() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Scan folder"; panel.message = "Only this folder is approved. Repositories, databases and cloud folders are excluded."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }
    func scan(_ url: URL) {
        root = url; duplicates = []; selection = "Storage"; busy = true; message = "Scanning \(url.lastPathComponent)…"
        scanIsStale = false
        let safety = FileSafety(protectedRoots: protectedFolders), bytes = Int64(min(1_000_000_000, max(0, minimumMB))) * 1_000_000, age = min(36_500, max(0, minimumAgeDays))
        Task {
            do {
                report = try await Task.detached(priority: .utility) { try FileScanner(safety: safety).scan(root: url, minimumBytes: bytes, minimumAgeDays: age) }.value
                message = "\(report.candidates.count) files matched · \(report.excluded) excluded\(report.truncated ? " · Scan limit reached" : "")"
                watcher = try FolderWatcher(root: url) { [weak model = self] in Task { await model?.markScanStale() } }
            } catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
    private func markScanStale() { scanIsStale = true }
    func findDuplicates() {
        guard let root else { return }
        let report = report, safety = FileSafety(protectedRoots: protectedFolders)
        busy = true; message = "Comparing equal-size files · maximum 2 GB read…"
        Task {
            do { duplicates = try await Task.detached(priority: .utility) { try FileScanner(safety: safety).duplicateGroups(report, root: root) }.value; message = "\(duplicates.count) duplicate groups found within the read budget. Files were not changed." }
            catch { errorMessage = error.localizedDescription }; busy = false
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
        if let catalog { coordinator = makeCoordinator(catalog) }
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
        runTask("Uploading and verifying \(candidate.url.lastPathComponent)…") {
            let job = try await coordinator.enqueue(source: candidate.url, approvedRoot: root)
            try await coordinator.run(job.id)
        }
    }
    func resume(_ job: ArchiveJob) {
        guard let coordinator else { return }
        runTask("Resuming \(job.source.lastPathComponent)…") { try await coordinator.run(job.id) }
    }
    func restore(_ job: ArchiveJob) {
        guard let coordinator, let remoteID = job.remoteID, job.state == .verified else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Restore here"; panel.message = "Choose a destination. Existing files will never be overwritten."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        runTask("Downloading and verifying \(job.source.lastPathComponent)…") {
            _ = try await coordinator.restore(manifest: ArchiveManifest(job: job, driveFileID: remoteID), destination: destination)
        }
    }
    func restoreFromManifest() {
        guard let coordinator else { return }
        let manifestPanel = NSOpenPanel(); manifestPanel.canChooseDirectories = false; manifestPanel.canChooseFiles = true
        manifestPanel.prompt = "Read recovery manifest"; manifestPanel.message = "Choose a CloudNest JSON recovery manifest. This works without an original catalog."
        guard manifestPanel.runModal() == .OK, let url = manifestPanel.url else { return }
        do {
            let manifest = try ArchiveManifest.read(from: url)
            let destinationPanel = NSOpenPanel(); destinationPanel.canChooseDirectories = true; destinationPanel.canChooseFiles = false
            destinationPanel.prompt = "Restore here"; destinationPanel.message = "Restore \(manifest.fileName). Existing files are never overwritten."
            guard destinationPanel.runModal() == .OK, let destination = destinationPanel.url else { return }
            runTask("Restoring from a portable recovery manifest…") { _ = try await coordinator.restore(manifest: manifest, destination: destination) }
        } catch { errorMessage = error.localizedDescription }
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
    private func runTask(_ text: String, operation: @escaping @Sendable () async throws -> Void) {
        guard !busy else { return }; busy = true; message = text
        Task {
            do { try await operation(); message = "Completed. See the archive queue for local recovery and cloud status." }
            catch { errorMessage = (error as? NestError)?.localizedDescription ?? "The operation was interrupted. Review the queue and retry." }
            await refresh(); busy = false
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
                    Label(model.connected ? "Drive authorized" : "Drive not connected", systemImage: model.connected ? "checkmark.circle.fill" : "circle.dotted").font(.caption).foregroundStyle(model.connected ? .green : .secondary)
                    if model.busy { ProgressView().controlSize(.small).padding(.leading, 8) }
                }.padding(.horizontal, 30).padding(.vertical, 18)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.selection == "Overview" { overview }
                        else if model.selection == "Storage" { storage }
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
            Button(action: model.chooseAndScan) { Label("Scan folder", systemImage: "folder.badge.plus") }.disabled(model.busy)
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
            if !model.jobs.isEmpty {
                panel {
                    Text("Archive queue · latest 500").font(.headline)
                    ForEach(model.jobs) { job in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.source.lastPathComponent)
                                Text(job.lastError ?? "\(job.state.rawValue.capitalized) · \(model.format(job.offset)) of \(model.format(job.snapshot.identity.size))").font(.caption).foregroundStyle(job.lastError == nil ? Color.secondary : Color.orange)
                            }
                            Spacer()
                            if job.state == .verified {
                                VStack(alignment: .trailing, spacing: 6) {
                                    HStack {
                                        Button("Restore…") { model.restore(job) }
                                        if job.recovery == nil { Button("Reclaim…") { model.retainForCleanup(job) } }
                                        else if job.recovery?.stage == .retained || job.recovery?.stage == .needsReview {
                                            Button("Put back") { model.recoverOriginal(job) }
                                            if job.recovery?.stage == .retained { Button("Remove copy…", role: .destructive) { model.removeRecovery(job) } }
                                        }
                                    }.disabled(model.busy || !model.connected)
                                    if let recovery = job.recovery { Text("Local: \(recovery.stage.rawValue) · \(model.format(recovery.retainedBytes)) retained").font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            else { Button("Resume / verify") { model.resume(job) }.disabled(model.busy || !model.connected) }
                        }.padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
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
