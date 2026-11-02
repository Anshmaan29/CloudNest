import SwiftUI
import AppKit
import CloudNestCore

private final class SweepProgressDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true, pending = false
    private var next: TimeInterval = 0
    private var latest: SmartSweepProgress?
    func offer(_ value: SmartSweepProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }; latest = value
        let now = ProcessInfo.processInfo.systemUptime
        guard !pending, now >= next else { return false }; pending = true; next = now + 0.2; return true
    }
    func take() -> SmartSweepProgress? { lock.lock(); defer { lock.unlock() }; pending = false; return active ? latest : nil }
    func invalidate() { lock.lock(); active = false; latest = nil; lock.unlock() }
}
@MainActor private final class SmartSweepModel: ObservableObject {
    @Published var kind: SmartSweepKind = .nodeModules
    @Published var root: URL?
    @Published var editsAcknowledged = false
    @Published var preview: SmartSweepPreview?
    @Published var recoveries: [SmartSweepRecovery] = []
    @Published var recoveryParent: URL?
    @Published var loadingRecoveries = false
    @Published var busy = false
    @Published var progressEntries = 0
    @Published var progressBytes: Int64 = 0
    @Published var message = "Choose one generated folder. Nothing is scanned until you request a preview."
    @Published var error: String?
    @Published var cleanup: SmartSweepCleanupResult?
    private var task: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var delivery: SweepProgressDelivery?
    private var generation = UUID()
    func selectRoot() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Select generated folder"; panel.message = kind.regenerationNote
        if panel.runModal() == .OK { root = panel.url; preview = nil; cleanup = nil }
    }
    func selectRecoveryParent() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Choose original parent"; panel.message = "Choose the parent that contains the hidden .cloudnest-sweep-recovery folder. Recovery is entirely local and works offline."
        if panel.runModal() == .OK { recoveryParent = panel.url; refreshRecoveries() }
    }
    func refreshRecoveries() {
        guard let recoveryParent else { return }
        recoveryTask?.cancel(); loadingRecoveries = true
        let request = UUID(); recoveryGeneration = request
        recoveryTask = Task {
            let worker = Task.detached(priority: .utility) { try SmartSweep.recoveries(under: recoveryParent) }
            do {
                let values = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, recoveryGeneration == request else { return }
                recoveries = values
            } catch {
                guard !Task.isCancelled, recoveryGeneration == request else { return }
                self.error = error.localizedDescription
            }
            loadingRecoveries = false; recoveryTask = nil
        }
    }
    private var recoveryGeneration = UUID()
    func requestPreview(protectedRoots: [URL], busyChanged: ((Bool) -> Void)?) {
        guard let root else { return }
        let kind = kind, acknowledged = editsAcknowledged
        preview = nil; cleanup = nil
        run(protectedRoots: protectedRoots, busyChanged: busyChanged, status: "Checking the selected root, active processes and every member…") { driver, progress in
            .preview(try await driver.preview(root: root, kind: kind, dependencyEditsAcknowledged: acknowledged, onProgress: progress))
        }
    }
    func stage(protectedRoots: [URL], busyChanged: ((Bool) -> Void)?) {
        guard let preview else { return }
        let alert = NSAlert(); alert.messageText = "Stage this selected folder for local recovery?"
        alert.informativeText = "\(preview.root.path)\n\n\(preview.entryCount) reviewed entries will move atomically into a private hidden sibling recovery job. This does not free the estimated disk space yet. Nothing is permanently deleted. The original path becomes absent so its owning tool may regenerate it.\n\n\(preview.kind.regenerationNote)"
        alert.addButton(withTitle: "Move to local recovery"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        recoveryParent = preview.root.deletingLastPathComponent()
        run(protectedRoots: protectedRoots, busyChanged: busyChanged, status: "Rechecking and moving the reviewed folder into local recovery…") { driver, _ in .staged(try await driver.stage(approved: preview)) }
    }
    func putBack(_ recovery: SmartSweepRecovery, protectedRoots: [URL], busyChanged: ((Bool) -> Void)?) {
        let alert = NSAlert(); alert.messageText = "Put this local recovery folder back?"
        alert.informativeText = "\(recovery.originalRoot.path)\n\nThe original path must be absent. CloudNest will never merge with or overwrite a regenerated folder. Changed or interrupted staging can be put back as a whole; retain the journal if any warning remains."
        alert.addButton(withTitle: "Put back without overwriting"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(protectedRoots: protectedRoots, busyChanged: busyChanged, status: "Checking the original destination and putting back the local folder…") { driver, _ in try await driver.putBack(approved: recovery); return .putBack }
    }
    func purge(_ recovery: SmartSweepRecovery, protectedRoots: [URL], busyChanged: ((Bool) -> Void)?) {
        let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "Permanently delete this staged generated folder?"
        alert.informativeText = "Original selection: \(recovery.originalRoot.path)\n\nThis deletes only the reviewed staged inventory. Put-back will no longer be possible. Local dependency edits may be lost. Stop build/install tools first. New, changed, shared or in-use content blocks cleanup. An interruption can leave a partially cleaned private job; cleanup never resumes automatically.\n\n\(recovery.kind.regenerationNote)"
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Permanently delete staged content")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        run(protectedRoots: protectedRoots, busyChanged: busyChanged, status: "Verifying every staged member before permanent cleanup…") { driver, progress in .cleaned(try await driver.purge(approved: recovery, permanentlyDeleteAcknowledged: true, onProgress: progress)) }
    }
    private enum Outcome: Sendable { case preview(SmartSweepPreview), staged(SmartSweepRecovery), putBack, cleaned(SmartSweepCleanupResult) }
    private func run(protectedRoots: [URL], busyChanged: ((Bool) -> Void)?, status: String,
                     work: @escaping @Sendable (SmartSweep, @Sendable (SmartSweepProgress) -> Void) async throws -> Outcome) {
        guard !busy else { return }
        busy = true; busyChanged?(true); message = status; error = nil; progressEntries = 0; progressBytes = 0
        let request = UUID(), progress = SweepProgressDelivery(), model = self
        generation = request; delivery = progress
        let driver = SmartSweep(protectedRoots: protectedRoots)
        task = Task { [model] in
            let worker = Task.detached(priority: .utility) {
                try await work(driver) { value in
                    guard progress.offer(value) else { return }
                    Task { @MainActor [weak model] in
                        guard let value = progress.take(), model?.generation == request else { return }
                        model?.progressEntries = value.entries; model?.progressBytes = value.logicalBytes
                    }
                }
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { progress.invalidate(); worker.cancel() })
                switch result {
                case .preview(let value): preview = value; message = "Dry run complete. Review the exact selection and regeneration notes before staging."
                case .staged: preview = nil; message = "Staged locally. No disk-space recovery is claimed until separately approved permanent cleanup."
                case .putBack: message = "Local folder put back without overwriting another path."
                case .cleaned(let value): cleanup = value; message = "Reviewed staged entries cleaned. Volume free-space change is an observation, not a guaranteed reclaimed size."
                }
            } catch is CancellationError { message = "Stopped. Originals or remaining staged content are retained. Review local recovery before another action." }
            catch { self.error = error.localizedDescription; message = "Operation did not complete. Retain originals, recovery payload and journal; no automatic cleanup will run." }
            progress.invalidate(); generation = UUID(); delivery = nil; task = nil; busy = false
            refreshRecoveries(); busyChanged?(false)
        }
    }
    func cancel() { generation = UUID(); delivery?.invalidate(); task?.cancel(); recoveryGeneration = UUID(); recoveryTask?.cancel(); recoveryTask = nil; loadingRecoveries = false }
}

struct SmartSweepView: View {
    var protectedRoots: [URL] = []
    var operationBusyChanged: ((Bool) -> Void)?
    @StateObject private var model = SmartSweepModel()
    init(protectedRoots: [URL] = [], operationBusyChanged: ((Bool) -> Void)? = nil) { self.protectedRoots = protectedRoots; self.operationBusyChanged = operationBusyChanged }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Smart Sweep").font(.largeTitle.bold())
                Text("Review one regenerable folder, stage it locally, then choose put-back or a separate permanent cleanup. No automatic scans or deletion.").foregroundStyle(.secondary)
                GroupBox("1. Select and preview") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Generated folder type", selection: $model.kind) { ForEach(SmartSweepKind.allCases) { Text($0.title).tag($0) } }
                            .onChange(of: model.kind) { _, _ in model.preview = nil; model.root = nil }
                        Text(model.kind.regenerationNote).font(.callout).foregroundStyle(.secondary)
                        HStack { Text(model.root?.path ?? "No folder selected").font(.caption).textSelection(.enabled); Spacer(); Button("Choose folder…", action: model.selectRoot).keyboardShortcut("o", modifiers: [.command, .shift]) }
                        if model.kind == .nodeModules {
                            Toggle("I understand local dependency edits and linked/generated dependency content may be lost after permanent cleanup.", isOn: $model.editsAcknowledged)
                                .onChange(of: model.editsAcknowledged) { _, _ in model.preview = nil }
                        }
                        Button("Run safe preview") { model.requestPreview(protectedRoots: protectedRoots, busyChanged: operationBusyChanged) }
                            .buttonStyle(.borderedProminent).disabled(model.root == nil || model.kind == .nodeModules && !model.editsAcknowledged)
                    }.padding(8)
                }.disabled(model.busy)
                if let preview = model.preview {
                    GroupBox("2. Review before local staging") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(preview.root.path).font(.caption).textSelection(.enabled)
                            Text("\(preview.entryCount) entries · \(bytes(preview.logicalBytes)) unique logical bytes · \(bytes(preview.estimatedAllocatedBytes)) estimated allocated file blocks")
                            Text("\(preview.symbolicLinkCount) links inventoried without following their targets. \(preview.sharedInodesExcluded) shared inodes excluded from the space estimate.").font(.caption)
                            Text("Allocated blocks are an estimate. APFS clones/snapshots, compression and concurrent volume activity can change actual free space. Staging itself does not reclaim these bytes.").font(.caption).foregroundStyle(.secondary)
                            Button("Review and stage locally…") { model.stage(protectedRoots: protectedRoots, busyChanged: operationBusyChanged) }
                        }.padding(8)
                    }.disabled(model.busy)
                }
                GroupBox("3. Local recovery and separate cleanup") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Button("Choose original parent…", action: model.selectRecoveryParent); Button("Refresh recovery", action: model.refreshRecoveries).disabled(model.recoveryParent == nil) }
                        if model.loadingRecoveries { ProgressView("Loading local recovery jobs…").controlSize(.small) }
                        if let parent = model.recoveryParent { Text(parent.path).font(.caption).textSelection(.enabled) }
                        if model.recoveries.isEmpty { Text("No local jobs loaded. Choose an original parent to inspect its recovery catalog.").foregroundStyle(.secondary) }
                        ForEach(model.recoveries) { recovery in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(recovery.originalRoot.path).font(.caption).textSelection(.enabled)
                                Text("\(recovery.kind.title) · \(recovery.entryCount) reviewed entries · \(recovery.state)").font(.callout)
                                HStack {
                                    Button("Show recovery") { NSWorkspace.shared.activateFileViewerSelecting([recovery.directory]) }
                                    Button("Put back…") { model.putBack(recovery, protectedRoots: protectedRoots, busyChanged: operationBusyChanged) }.disabled(!["prepared", "staged", "uncertain", "putBackStarted"].contains(recovery.state))
                                    Button("Permanent cleanup…", role: .destructive) { model.purge(recovery, protectedRoots: protectedRoots, busyChanged: operationBusyChanged) }.disabled(recovery.state != "staged")
                                }
                            }.accessibilityElement(children: .contain)
                            Divider()
                        }
                    }.padding(8)
                }.disabled(model.busy)
                if let cleanup = model.cleanup {
                    Text("Removed \(cleanup.removedEntries) reviewed entries. Estimated allocated blocks: \(bytes(cleanup.estimatedAllocatedBytes)). Observed volume free-space delta: \(cleanup.observedVolumeFreeBytesDelta) bytes.").font(.callout).textSelection(.enabled)
                }
                HStack {
                    if model.busy { ProgressView().controlSize(.small); Text("\(model.progressEntries) entries · \(bytes(model.progressBytes))"); Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction) }
                    Text(model.message).font(.callout).foregroundStyle(.secondary).accessibilityLabel("Smart Sweep status: " + model.message)
                }.accessibilityElement(children: .contain)
            }.padding(24).frame(maxWidth: 920, alignment: .leading)
        }
        .onDisappear { model.cancel() }
        .alert("Smart Sweep retained your data", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
