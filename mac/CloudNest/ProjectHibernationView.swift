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
    @Published var exclusionsReviewed = false
    @Published var capsule: ProjectCapsuleResult?
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
                Text("Git commit, branch, dirty/untracked state, source, important assets and dependency manifests are recorded. History, credentials, caches, database storage and symlinks are excluded; no scripts are executed.").font(.caption).foregroundStyle(.secondary)
                TextField("Relevant decisions — optional, owner supplied", text: $model.decisions, axis: .vertical)
                TextField("Next action when resuming — optional", text: $model.nextAction, axis: .vertical)
                Button("Create verified local snapshot", action: create).disabled(model.source == nil || model.destination == nil || !model.inactiveAcknowledged)
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
                    Button("Archive snapshot and build Memory Card", action: archive).disabled(!connected || !model.exclusionsReviewed || model.card != nil)
                    if !connected { Text("Connect Google Drive in Settings to continue.").font(.caption).foregroundStyle(.secondary) }
                    Text("This snapshot is not a complete repository/history backup. Original cleanup remains unavailable even after upload.").font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy || operationBusy)
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
        if source { model.source = url } else { model.destination = url }
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
            model.card = nil; model.exclusionsReviewed = false
            model.status = "Existing snapshot loaded. Review exclusions; archive verification is required before a card can be generated."
        }
    }
    private func create() {
        guard let source = model.source, let destination = model.destination, model.inactiveAcknowledged else { return }
        begin {
            model.capsule = nil; model.card = nil; model.exclusionsReviewed = false
            let builder = ProjectHibernation(protectedRoots: protectedFolders)
            let task = Task.detached(priority: .utility) { try builder.create(source: source, destination: destination) }
            model.capsule = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            model.status = "Snapshot verified locally. Review all included files and exclusions before upload."
        }
    }
    private func archive() {
        guard let capsule = model.capsule, model.exclusionsReviewed else { return }
        let decisions = model.decisions, next = model.nextAction
        begin {
            let check = Task.detached(priority: .utility) { try ProjectHibernation.requireInactive(URL(fileURLWithPath: capsule.manifest.originalPath)) }
            try await withTaskCancellationHandler(operation: { try await check.value }, onCancel: { check.cancel() })
            let verified = try await onArchive(capsule)
            try Task.checkCancellation()
            let task = Task.detached(priority: .utility) { try ProjectHibernation.memoryCard(capsule: capsule, verifiedArchive: verified, decisions: decisions, nextAction: next) }
            let card = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            model.card = card; model.cardBody = card.body; model.cardTitle = card.title
            model.status = "Drive archive verified. Edit and approve your private Memory Card."
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
        model.busy = true; model.error = nil; operationBusyChanged(true)
        model.task = Task { @MainActor in
            defer { model.busy = false; model.task = nil; operationBusyChanged(false) }
            do { try await action() }
            catch is CancellationError { model.status = "Cancelled safely. Existing local snapshots and queued archives remain recoverable in Storage." }
            catch { model.error = error.localizedDescription }
        }
    }
}
