import SwiftUI
import AppKit
import CloudNestCore

@MainActor
private final class DeveloperSnapshotModel: ObservableObject {
    @Published var source: URL?
    @Published var destination: URL?
    @Published var projectDescription = ""
    @Published var maximumGB = 2
    @Published var result: ProjectCapsuleResult?
    @Published var busy = false
    @Published var reviewedFiles = 0
    @Published var totalFiles = 0
    @Published var message = "Select a Git project and a local destination outside the repository."
    @Published var error: String?
    private var operation: Task<Void, Never>?
    private var generation: UUID?
    func chooseSource() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Choose Git project"
        panel.message = "Select the repository root. CloudNest will not execute source code or change this working tree."
        if panel.runModal() == .OK { source = panel.url; result = nil }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Create snapshot here"
        panel.message = "Choose a local destination outside Git, cloud folders and protected paths. Space is checked before copying."
        if panel.runModal() == .OK { destination = panel.url; result = nil }
    }
    func create(protectedRoots: [URL]) {
        guard !busy, let source, let destination else { return }
        let confirmation = NSAlert(); confirmation.messageText = "Create a Project Time Capsule?"
        confirmation.informativeText = "CloudNest will copy this selected working tree into a private local snapshot, record Git state, and exclude repository internals, credentials, dependencies and caches. Review all exclusions before uploading. The source repository stays in place and is never approved for cleanup."
        confirmation.addButton(withTitle: "Create snapshot"); confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        let description = projectDescription, budget = maximumGB
        busy = true; result = nil; reviewedFiles = 0; totalFiles = 0; message = "Inspecting Git state and local project files…"
        let request = UUID(); generation = request
        operation = Task {
            do {
                var limits = ProjectCapsuleLimits(); limits.maximumBytes = Int64(min(20, max(1, budget))) * 1_000_000_000
                let builder = ProjectTimeCapsule(protectedRoots: protectedRoots, limits: limits)
                let copy = Task.detached(priority: .utility) { [model = self] in
                    try builder.create(source: source, destination: destination, description: description, onProgress: { count, total in
                        Task { @MainActor [weak model] in
                            if model?.generation == request { model?.reviewedFiles = count; model?.totalFiles = total }
                        }
                    })
                }
                let completed = try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
                result = completed
                message = "Verified local snapshot created. Review its manifest and recovery checklist before archiving. The original project is unchanged."
            } catch is CancellationError { message = "Snapshot cancelled. The original project was not changed. Incomplete staging stays protected from ordinary archiving." }
            catch { self.error = error.localizedDescription; message = "Snapshot did not complete. The original project was not changed." }
            busy = false; operation = nil; generation = nil
        }
    }
    func cancel() { message = "Stopping safely…"; operation?.cancel() }
    func revealManifest() { if let result { NSWorkspace.shared.activateFileViewerSelecting([result.manifestURL]) } }
    func revealFolder() { if let result { NSWorkspace.shared.activateFileViewerSelecting([result.directory]) } }
}

struct DeveloperView: View {
    var protectedRoots: [URL] = []
    var archiveCapsule: ((URL) -> Void)?
    @StateObject private var model = DeveloperSnapshotModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep the project. Lose the guesswork.").font(.largeTitle.bold())
                Text("A reproducible working-tree snapshot with Git references, dependency manifests and a recovery checklist. Source files are copied, never offloaded.").foregroundStyle(.secondary)
            }
            ProductPanel {
                Label("Project Time Capsule", systemImage: "shippingbox").font(.headline)
                HStack { VStack(alignment: .leading, spacing: 5) { Text("Git project").font(.caption).foregroundStyle(.secondary); Text(model.source?.path ?? "Select the repository root").textSelection(.enabled) }; Spacer(); Button("Choose project…", action: model.chooseSource) }
                HStack { VStack(alignment: .leading, spacing: 5) { Text("Snapshot destination").font(.caption).foregroundStyle(.secondary); Text(model.destination?.path ?? "Select a local folder outside the repository").textSelection(.enabled) }; Spacer(); Button("Choose destination…", action: model.chooseDestination) }
                TextField("Optional project description", text: $model.projectDescription)
                Stepper("Maximum snapshot data: \(model.maximumGB) GB", value: $model.maximumGB, in: 1...20)
                Text("At most 9,900 entries and 48 levels. The destination must retain a 512 MB safety margin. Byte limits are checked before copying; files stream in bounded chunks.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Create snapshot") { model.create(protectedRoots: protectedRoots) }.buttonStyle(.borderedProminent).disabled(model.source == nil || model.destination == nil); Spacer() }
            }.disabled(model.busy)
            if model.busy {
                ProductPanel {
                    HStack { ProgressView().controlSize(.small); Text(model.message); Spacer(); Button("Cancel", action: model.cancel) }
                    Text("Keep this screen open until completion. Navigating away cancels the snapshot safely.").font(.caption).foregroundStyle(.secondary)
                    if model.totalFiles > 0 { ProgressView(value: Double(model.reviewedFiles), total: Double(model.totalFiles)); Text("\(model.reviewedFiles) of \(model.totalFiles) files reviewed").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let result = model.result {
                ProductPanel {
                    Label("Local snapshot verified", systemImage: "checkmark.seal").font(.headline)
                    Text(result.directory.path).font(.caption).textSelection(.enabled)
                    HStack {
                        Text("\(result.manifest.files.count) files · \(result.manifest.excluded.count) exclusions").font(.callout)
                        Spacer(); Text("\(result.manifest.git.commit.prefix(12)) · \(result.manifest.git.branch ?? "detached HEAD")").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text("\(result.manifest.git.trackedChanges.count) tracked change records · \(result.manifest.git.untrackedFiles.count) copied files outside the Git index").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Review manifest", action: model.revealManifest); Button("Show snapshot in Finder", action: model.revealFolder); if let archiveCapsule { Button("Review cloud archive…") { archiveCapsule(result.directory) }.buttonStyle(.borderedProminent) } }
                    Text("Potential secrets are detected conservatively, not exhaustively. Inspect included files and exclusions before upload. No original-project cleanup is authorized.").font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.busy { Text(model.message).foregroundStyle(.secondary) }
            ProductPanel {
                Label("A recovery path, not a live-disk move", systemImage: "lock.shield").font(.headline)
                Text("Git internals, private environment files, keys, caches, dependencies, symbolic links, cloud placeholders and database/VM storage are excluded. Safe environment templates and executable status are preserved. Full macOS metadata and hard-link topology are not claimed.").foregroundStyle(.secondary)
                Text("The capsule can use CloudNest’s ordinary folder archive/restore flow. Reconnect Git remotes and rebuild dependencies only after reviewing the included instructions and source scripts. Running Docker disks and live database storage are never copied by this feature.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { if model.busy { model.cancel() } }
        .alert("Project Time Capsule", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
