import SwiftUI
import AppKit
import CloudNestCore

// Coalesce on the worker thread before scheduling UI work. Even when the main
// actor is busy, each job can have only one pending progress delivery.
private final class DatabaseSnapshotProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var pending = false
    private var latest: Int64 = 0
    private var nextDelivery: TimeInterval = 0
    func offer(_ bytes: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        latest = bytes
        let now = ProcessInfo.processInfo.systemUptime
        guard !pending, now >= nextDelivery else { return false }
        pending = true; nextDelivery = now + 0.2
        return true
    }
    func take() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        pending = false
        return active ? latest : nil
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }
}

@MainActor private final class DatabaseBackupModel: ObservableObject {
    @Published var source: URL?
    @Published var destination: URL?
    @Published var review: DatabaseSnapshotReview?
    @Published var result: DatabaseSnapshotResult?
    @Published var busy = false
    @Published var maximumGB = 10
    @Published var bytes: Int64 = 0
    @Published var message = "Choose one SQLite database and a separate local backup destination."
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var progress: DatabaseSnapshotProgress?
    func chooseSource() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.prompt = "Select SQLite database"
        panel.message = "Select one database you own outside repositories, cloud and protected folders. Its file and immediate folder must be owner-private. CloudNest will not copy raw database directories or virtual disks."
        if panel.runModal() == .OK { source = panel.url; result = nil }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Choose destination"
        panel.message = "Each verified snapshot is published in a new private folder. Existing files are never overwritten."
        if panel.runModal() == .OK { destination = panel.url }
    }
    func chooseReview() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Review SQLite snapshot"
        if panel.runModal() == .OK, let directory = panel.url {
            do { review = try DatabaseSnapshot.review(directory: directory) } catch { self.error = error.localizedDescription }
        }
    }
    func create(protectedRoots: [URL]) {
        guard let source, let destination else { return }
        let alert = NSAlert(); alert.messageText = "Create a consistent SQLite snapshot?"
        alert.informativeText = "Selected: \(source.lastPathComponent)\n\nCloudNest will read the database through SQLite's backup API, including committed WAL data when its existing shared-memory files support read-only access. It will not checkpoint, repair or remove your source. The new backup may contain private data. Other database engines and Docker volumes require their own backup tools."
        alert.addButton(withTitle: "Create snapshot"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(protectedRoots: protectedRoots) { driver, progress in try driver.create(source: source, to: destination, onProgress: progress) }
    }
    func restore(protectedRoots: [URL]) {
        guard let review, let destination else { return }
        let alert = NSAlert(); alert.messageText = "Restore this verified snapshot to a new folder?"
        alert.informativeText = "Database: \(review.manifest.sourceName)\n\nThe stored payload must match its size and SHA-256 and pass SQLite quick_check. Restoration creates a new private folder at the selected destination. Use the owning application's import/open workflow afterward; CloudNest will not replace a running database."
        alert.addButton(withTitle: "Verify and restore"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(protectedRoots: protectedRoots) { driver, progress in try driver.restore(approved: review, to: destination, onProgress: progress) }
    }
    private func run(protectedRoots: [URL], work: @escaping @Sendable (DatabaseSnapshot, @Sendable (Int64) -> Void) throws -> DatabaseSnapshotResult) {
        guard !busy else { return }; busy = true; bytes = 0; result = nil
        let request = UUID(), delivery = DatabaseSnapshotProgress()
        generation = request; progress = delivery
        message = "Creating and verifying a private snapshot…"
        var limits = DatabaseSnapshotLimits(); limits.maximumBytes = Int64(maximumGB) * 1_000_000_000
        let driver = DatabaseSnapshot(protectedRoots: protectedRoots, limits: limits), model = self
        task = Task { [model] in
            let job = Task.detached(priority: .utility) {
                try work(driver, { count in
                    guard delivery.offer(count) else { return }
                    Task { @MainActor [weak model] in
                        guard let count = delivery.take(), model?.generation == request else { return }
                        model?.bytes = count
                    }
                })
            }
            do {
                let verified = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { delivery.invalidate(); job.cancel() })
                delivery.invalidate(); result = verified; bytes = verified.manifest.bytes
                message = "Snapshot verified. The source remains in place. Review the manifest before archiving or opening the restored database."
            } catch is CancellationError { message = "Stopped. Any partial staging remains private; the source is retained." }
            catch { self.error = error.localizedDescription; message = "Snapshot was not reported as complete. Retain and inspect any staging or synchronization warning before using it." }
            delivery.invalidate(); generation = UUID(); progress = nil
            busy = false; task = nil
        }
    }
    func cancel() { generation = UUID(); progress?.invalidate(); task?.cancel() }
}

struct DatabaseBackupView: View {
    var protectedRoots: [URL] = []
    var archiveBackup: ((URL) -> Void)?
    @StateObject private var model = DatabaseBackupModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("SQLite snapshots").font(.largeTitle.bold())
            Text("Consistent, verified backups of one explicitly selected database. Original data stays in its application.").foregroundStyle(.secondary)
            ProductPanel {
                Label("Create a snapshot", systemImage: "externaldrive.badge.checkmark").font(.headline)
                HStack { Text(model.source?.path ?? "No database selected").font(.caption).textSelection(.enabled); Spacer(); Button("Select database…", action: model.chooseSource) }
                HStack { Text(model.destination?.path ?? "No destination selected").font(.caption).textSelection(.enabled); Spacer(); Button("Choose destination…", action: model.chooseDestination) }
                Stepper("Maximum snapshot: \(model.maximumGB) GB", value: $model.maximumGB, in: 1...100)
                Button("Review and create…") { model.create(protectedRoots: protectedRoots) }.buttonStyle(.borderedProminent).disabled(model.source == nil || model.destination == nil)
                Text("Source access is read-only and time bounded. Missing WAL sidecars, an open connection inside CloudNest, unsafe paths or insufficient disk space block the operation. No live Docker disk or volume is copied.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            ProductPanel {
                Label("Restore a snapshot", systemImage: "arrow.down.doc").font(.headline)
                Button("Choose backup to review…", action: model.chooseReview)
                if let review = model.review {
                    Text(review.manifest.sourceName).font(.headline)
                    Text("\(ByteCountFormatter.string(fromByteCount: review.manifest.bytes, countStyle: .file)) · \(review.manifest.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Verify and restore to a new folder…") { model.restore(protectedRoots: protectedRoots) }.disabled(model.destination == nil)
                }
            }.disabled(model.busy)
            if let result = model.result {
                ProductPanel {
                    Label("Verified SQLite snapshot", systemImage: "checkmark.seal").font(.headline)
                    Text(result.directory.path).font(.caption).textSelection(.enabled)
                    HStack { Button("Review manifest") { NSWorkspace.shared.activateFileViewerSelecting([result.manifestURL]) }; Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.directory]) }; if let archiveBackup { Button("Review cloud archive…") { archiveBackup(result.directory) } } }
                }
            }
            HStack { if model.busy { ProgressView().controlSize(.small); Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)); Button("Cancel", action: model.cancel) }; Text(model.message).font(.caption).foregroundStyle(.secondary) }
        }
        .alert("SQLite snapshot", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
