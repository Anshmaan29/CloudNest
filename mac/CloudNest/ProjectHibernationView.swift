import SwiftUI
import AppKit
import CloudNestCore

@MainActor
private final class HibernationState: ObservableObject {
    @Published var source: URL?
    @Published var destination: URL?
    @Published var decisions = ""
    @Published var nextAction = ""
    @Published var inactiveAcknowledged = false
    @Published var includeGitRecovery = true
    @Published var historyAcknowledged = false
    @Published var exclusionsReviewed = false
    @Published var capsule: ProjectCapsuleResult?
    @Published var capsuleContainsGitRecovery = false
    @Published var card: ProjectMemoryCard?
    @Published var cardBody = ""
    @Published var cardTitle = ""
    @Published var busy = false
    @Published var error: String?
    @Published var status = "Choose an inactive Git project and a local snapshot destination."
    var task: Task<Void, Never>?
}

struct ProjectHibernationView: View {
    let connected: Bool
    var brainConnected = false
    let operationBusy: Bool
    var protectedFolders: [URL] = []
    let onArchive: @MainActor (ProjectCapsuleResult) async throws -> FolderArchiveJob
    let onSaveCard: @MainActor (ProjectMemoryCard) async throws -> Void
    var operationBusyChanged: @MainActor (Bool) -> Void = { _ in }
    var acquireOperation: @MainActor () -> (@MainActor () -> Void)? = { {} }
    @StateObject private var model = HibernationState()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Hibernate Project").font(.largeTitle.bold())
            Text("Archive a reviewed source snapshot and preserve an editable AI Memory Card. Your original repository stays in place.").foregroundStyle(.secondary)
            ProductPanel {
                Label("1 · Preserve the project", systemImage: "shippingbox").font(.headline)
                Text(model.source?.path ?? "No project selected").textSelection(.enabled)
                Button("Choose inactive Git project…") { choose(source: true) }
                Button("Resume from existing local snapshot…", action: recoverCapsule)
                Text(model.destination?.path ?? "No snapshot destination selected").textSelection(.enabled)
                Button("Choose snapshot destination…") { choose(source: false) }
                Toggle("I closed project editors, terminals and development processes", isOn: $model.inactiveAcknowledged)
                Text("Git commit, branch, staged/unstaged state, source, assets and dependency manifests are recorded. Optional recovery adds complete referenced history, stashes and index objects. Configuration/hooks are never activated and no project scripts run.").font(.caption).foregroundStyle(.secondary)
                Toggle("Include portable Git recovery", isOn: $model.includeGitRecovery)
                if model.includeGitRecovery { Toggle("I reviewed private-history risk: Git history, staged objects and reflogs can contain old credentials and personal data. Keep this archive private.", isOn: $model.historyAcknowledged) }
                TextField("Relevant decisions — optional, owner supplied", text: $model.decisions, axis: .vertical)
                TextField("Next action when resuming — optional", text: $model.nextAction, axis: .vertical)
                Button("Create verified local snapshot", action: create).disabled(model.source == nil || model.destination == nil || !model.inactiveAcknowledged || model.includeGitRecovery && !model.historyAcknowledged)
            }.disabled(model.busy || operationBusy)
            if let capsule = model.capsule {
                ProductPanel {
                    Label("2 · Review and archive", systemImage: "checklist").font(.headline)
                    Text("\(capsule.manifest.files.count) files · \(capsule.manifest.excluded.count) exclusions · \(capsule.manifest.git.commit.prefix(12))").font(.callout)
                    Button("Review complete manifest in Finder") { NSWorkspace.shared.activateFileViewerSelecting([capsule.manifestURL]) }
                    if !capsule.manifest.excluded.isEmpty {
                        ScrollView { VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(capsule.manifest.excluded.enumerated()), id: \.offset) { _, item in
                                Text("\(item.path): \(item.reason)").font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                    }
                    Toggle("I reviewed included files and every exclusion", isOn: $model.exclusionsReviewed)
                    Button("Archive snapshot and build Memory Card", action: archive).disabled(!connected || !model.exclusionsReviewed || model.card != nil || model.capsuleContainsGitRecovery && !model.historyAcknowledged)
                    if !connected { Text("Connect Google Drive in Settings to continue.").font(.caption).foregroundStyle(.secondary) }
                    Text("Git recovery, when selected, restores referenced history, stashes, staged index and included working files. Excluded private working files and custom configuration require independent recovery; original cleanup stays unavailable.").font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy || operationBusy)
            }
            ProductPanel {
                Label("Recover a project", systemImage: "arrow.uturn.backward").font(.headline)
                Text("First download and verify your capsule through Archive Library. Then choose the reviewed local capsule and an empty destination parent. Git history and staged state restore without checkout, hooks or network access. Existing projects are never overwritten.").font(.callout)
                Button("Restore Git project from a reviewed capsule…", action: restore).disabled(model.busy || operationBusy)
            }
            if model.card != nil {
                ProductPanel {
                    Label("3 · Review your private AI Memory Card", systemImage: "brain").font(.headline)
                    TextField("Card title", text: $model.cardTitle)
                    TextEditor(text: $model.cardBody).font(.system(.body, design: .monospaced)).frame(minHeight: 260).accessibilityLabel("Editable project memory card")
                    HStack {
                        Button("Save private card to Brain", action: save).disabled(!brainConnected || model.cardBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Copy card") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.cardBody, forType: .string); model.status = "Memory Card copied. Share only with assistants you authorize." }
                    }
                    if !brainConnected { Text("Connect the optional Brain to save. You can copy this reviewed card now.").font(.caption).foregroundStyle(.secondary) }
                    Text("Private cards are not automatically shared with connected AI clients. Review any context pack before sharing it.").font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy || operationBusy)
            }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.status).foregroundStyle(.secondary); Spacer(); if model.busy { Button("Cancel") { model.task?.cancel() } } }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.onDisappear { model.task?.cancel() }
    }
    private func choose(source: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = !source
        panel.prompt = source ? "Choose project" : "Create snapshot here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if source { model.source = url; model.historyAcknowledged = false } else { model.destination = url }
        model.capsule = nil; model.card = nil; model.exclusionsReviewed = false; model.inactiveAcknowledged = false
    }
    private func recoverCapsule() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Review snapshot"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        begin {
            let safety = FileSafety(protectedRoots: protectedFolders)
            let task = Task.detached(priority: .utility) { try ProjectHibernation.loadCapsule(at: directory, safety: safety) }
            model.capsule = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            model.capsuleContainsGitRecovery = model.capsule.map { FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent(ProjectGitRecovery.manifestName).path) } ?? false
            model.includeGitRecovery = model.capsuleContainsGitRecovery; model.historyAcknowledged = false
            model.card = nil; model.exclusionsReviewed = false
            model.status = "Existing snapshot loaded. Review exclusions; archive verification is required before a card can be generated."
        }
    }
    private func create() {
        guard let source = model.source, let destination = model.destination, model.inactiveAcknowledged else { return }
        let include = model.includeGitRecovery, acknowledged = model.historyAcknowledged
        begin {
            model.capsule = nil; model.card = nil; model.exclusionsReviewed = false
            let builder = ProjectHibernation(protectedRoots: protectedFolders)
            let task = Task.detached(priority: .utility) { try builder.create(source: source, destination: destination, includeGitRecovery: include, historyAcknowledged: acknowledged) }
            model.capsule = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            model.capsuleContainsGitRecovery = include
            model.status = "Snapshot verified locally. Review all included files and exclusions before upload."
        }
    }
    private func archive() {
        guard let capsule = model.capsule, model.exclusionsReviewed else { return }
        guard !model.capsuleContainsGitRecovery || model.historyAcknowledged else { model.error = "Acknowledge private Git history before uploading this recovery capsule."; return }
        let decisions = model.decisions, next = model.nextAction
        begin {
            let verified = try await onArchive(capsule)
            try Task.checkCancellation()
            let task = Task.detached(priority: .utility) { try ProjectHibernation.memoryCard(capsule: capsule, verifiedArchive: verified, decisions: decisions, nextAction: next) }
            let card = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            model.card = card; model.cardBody = card.body; model.cardTitle = card.title
            model.status = "Drive archive verified. Edit and approve your private Memory Card."
        }
    }
    private func restore() {
        let source = NSOpenPanel(); source.canChooseFiles = false; source.canChooseDirectories = true
        source.prompt = "Choose verified local capsule"; source.message = "Choose a capsule already restored and verified by Archive Library, containing GIT_RECOVERY.json."
        guard source.runModal() == .OK, let capsuleURL = source.url else { return }
        let target = NSOpenPanel(); target.canChooseFiles = false; target.canChooseDirectories = true
        target.prompt = "Restore new project here"; target.message = "A new project directory will be created. Existing directories are never overwritten."
        guard target.runModal() == .OK, let destination = target.url else { return }
        let review = NSAlert(); review.messageText = "Restore private Git history and staged state?"
        review.informativeText = "Select only your trusted capsule. Historical data can contain secrets. CloudNest restores source, objects, refs, stashes and index into a new private project, without activating original hooks/configuration, running source scripts, contacting remotes or removing the original repository. Review RESTORE.md before building."
        review.addButton(withTitle: "Verify and restore project"); review.addButton(withTitle: "Cancel")
        guard review.runModal() == .alertFirstButtonReturn else { return }
        let safety = FileSafety(protectedRoots: protectedFolders)
        begin {
            let worker = Task.detached(priority: .utility) {
                let capsule = try ProjectHibernation.loadCapsule(at: capsuleURL, safety: safety)
                return try ProjectGitRecovery.restore(capsule: capsule, destination: destination, historyAcknowledged: true, safety: safety)
            }
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            model.status = "Restored and verified \(result.sourceFiles) source files and \(result.references) Git references. Review dependencies and trusted configuration before resuming."
            NSWorkspace.shared.activateFileViewerSelecting([result.directory])
        }
    }
    private func save() {
        guard var card = model.card else { return }
        card.title = model.cardTitle; card.body = model.cardBody
        guard !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, card.title.utf8.count <= 200, card.body.utf8.count <= 20_000 else { model.error = "Use a title under 200 bytes and a card under 20 KB."; return }
        let edited = card
        begin { try await onSaveCard(edited); model.card = edited; model.status = "Reviewed project Memory Card saved privately to Brain." }
    }
    private func begin(_ action: @escaping @MainActor () async throws -> Void) {
        guard !model.busy, !operationBusy else { return }
        guard let release = acquireOperation() else { model.error = "Another operation is still finishing. Try again when it completes."; return }
        model.busy = true; model.error = nil; operationBusyChanged(true)
        model.task = Task { @MainActor in
            defer { model.busy = false; model.task = nil; operationBusyChanged(false); release() }
            do { try await action() }
            catch is CancellationError { model.status = "Cancelled safely. Existing local snapshots and queued archives remain recoverable in Storage." }
            catch { model.error = error.localizedDescription }
        }
    }
}
