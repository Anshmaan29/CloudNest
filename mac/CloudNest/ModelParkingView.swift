import SwiftUI
import AppKit
import CloudNestCore

@MainActor
private final class ModelParkingState: ObservableObject {
    @Published var preview: ModelParkingPreview?
    @Published var busy = false
    var operation: Task<Void, Never>?
    @Published var message = "Choose inactive weights or a portable model folder."
    @Published var error: String?
    @Published var confirmed = false
}

/// Upload completion is supplied by the application's verified archive queue.
struct ModelParkingView: View {
    let connected: Bool
    let operationBusy: Bool
    var statusMessage: String?
    var errorMessage: String?
    var protectedFolders: [URL] = []
    let onArchive: @MainActor (ModelParkingPreview) async throws -> Void
    let onOpenArchiveLibrary: @MainActor () -> Void
    var operationBusyChanged: @MainActor (Bool) -> Void = { _ in }
    @StateObject private var model = ModelParkingState()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("AI Model Parking").font(.largeTitle.bold())
            Text("Keep inactive model weights in Drive and restore them when needed. Models run locally after restoration; cloud parking does not run inference.").foregroundStyle(.secondary)
            ProductPanel {
                Label("Review before parking", systemImage: "externaldrive.badge.icloud").font(.headline)
                Text("Quit Ollama, LM Studio and other model runtimes first. Select .gguf, .safetensors or checkpoint files, a portable export, or only Ollama’s models folder. Account keys and linked cache trees are refused.").font(.callout)
                Button("Choose model files or folder…", action: choose).disabled(model.busy || operationBusy)
                if let preview = model.preview {
                    Text(preview.source.path).textSelection(.enabled)
                    Text("\(preview.kind) · \(preview.fileCount) files · \(ByteCountFormatter.string(fromByteCount: preview.logicalBytes, countStyle: .file))").foregroundStyle(.secondary)
                    Toggle("I reviewed this selection and closed model runtimes", isOn: $model.confirmed).disabled(model.busy)
                    Button("Archive and verify in Drive", action: archive).disabled(!connected || !model.confirmed || model.busy || operationBusy)
                }
                if !connected { Text("Connect Google Drive in Settings to archive models.").foregroundStyle(.secondary) }
            }
            ProductPanel {
                Label("Restore or reclaim", systemImage: "arrow.down.doc").font(.headline)
                Text("Use Archive Library for verified restore and separately approved local cleanup. Choose an empty destination; existing files are never overwritten. Ollama’s complete models folder preserves blobs and manifests together. Hugging Face cache symlinks require a portable regular-file export first.").font(.callout)
                Button("Open Archive Library", action: onOpenArchiveLibrary).disabled(model.busy)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(statusMessage ?? model.message).foregroundStyle(.secondary)
                Spacer()
                if model.busy { Button("Cancel") { model.operation?.cancel(); model.message = "Stopping safely…" } }
            }
            if let failure = model.error ?? errorMessage { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onDisappear { model.operation?.cancel() }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Review model"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        begin {
            model.preview = nil; model.confirmed = false
            let safety = FileSafety(protectedRoots: protectedFolders)
            let inspection = Task.detached(priority: .utility) { try ModelParking.preview(source: source, safety: safety) }
            model.preview = try await withTaskCancellationHandler(operation: { try await inspection.value }, onCancel: { inspection.cancel() })
            model.message = "Review the model selection. No files have been moved or deleted."
        }
    }
    private func archive() {
        guard let preview = model.preview, model.confirmed else { return }
        begin {
            let safety = FileSafety(protectedRoots: protectedFolders)
            let inspection = Task.detached(priority: .utility) { try ModelParking.revalidate(preview, safety: safety) }
            try await withTaskCancellationHandler(operation: { try await inspection.value }, onCancel: { inspection.cancel() })
            try Task.checkCancellation()
            try await onArchive(preview)
            model.message = "Model archive verified. Review Archive Library for restore and optional local cleanup."
            model.preview = nil; model.confirmed = false
        }
    }
    private func begin(_ action: @escaping @MainActor () async throws -> Void) {
        guard !model.busy, !operationBusy else { return }
        model.busy = true; model.error = nil; operationBusyChanged(true)
        model.operation = Task { @MainActor in
            defer { model.busy = false; model.operation = nil; operationBusyChanged(false) }
            do { try await action() }
            catch is CancellationError { model.message = "Operation cancelled. Check the archive queue before retrying." }
            catch { model.error = error.localizedDescription }
        }
    }
}
