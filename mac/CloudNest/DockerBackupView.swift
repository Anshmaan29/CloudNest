import SwiftUI
import AppKit
import CloudNestCore

@MainActor private final class DockerBackupModel: ObservableObject {
    @Published var reference = "" { didSet { if reference != oldValue { image = nil } } }
    @Published var image: ResolvedDockerImage?
    @Published var destination: URL?
    @Published var result: DockerBackupResult?
    @Published var review: DockerBackupReview?
    @Published var connectedVersion: String?
    @Published var maximumGB = 20
    @Published var busy = false
    @Published var bytes: Int64 = 0
    @Published var message = "Check the local Docker CLI and daemon when you are ready. CloudNest will not start Docker."
    @Published var error: String?
    private var operation: Task<Void, Never>?
    private var generation: UUID?
    private func start(_ label: String, work: @escaping @Sendable () throws -> String) {
        guard !busy else { return }; busy = true; message = label
        operation = Task {
            let job = Task.detached(priority: .utility) { try work() }
            do { message = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }) }
            catch is CancellationError { message = "Stopped. No partial backup was published. An interrupted import may already have added layers to Docker." }
            catch { self.error = error.localizedDescription; message = "Operation did not complete. Private staging may remain for review; no partial backup was published." }
            busy = false; operation = nil; generation = nil
        }
    }
    private func limits() -> DockerBackupLimits { var value = DockerBackupLimits(); value.maximumBytes = Int64(maximumGB) * 1_000_000_000; return value }
    func check(protectedRoots: [URL]) {
        let limits = limits(); connectedVersion = nil
        start("Checking the existing local Docker daemon…") { [weak self] in
            let driver = try DockerImageBackup.local(protectedRoots: protectedRoots, limits: limits)
            let version = try driver.checkConnection()
            Task { @MainActor [weak self] in self?.connectedVersion = version }
            return "Local Docker daemon connected. Choose one image to inspect; no containers or volumes were queried."
        }
    }
    func resolve(protectedRoots: [URL]) {
        let selected = reference, limits = limits(); image = nil
        start("Resolving only the selected image…") { [weak self] in
            let driver = try DockerImageBackup.local(protectedRoots: protectedRoots, limits: limits)
            let resolved = try driver.resolve(reference: selected)
            Task { @MainActor [weak self] in self?.image = resolved }
            return "The selected image has an immutable SHA-256 ID. Export saves that ID without stopping containers."
        }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Choose backup destination"
        panel.message = "Select a local folder outside Git, cloud and protected locations. Image layers can contain credentials: review your image before archiving."
        if panel.runModal() == .OK { destination = panel.url; result = nil }
    }
    func export(protectedRoots: [URL]) {
        guard let image, let destination else { return }
        let alert = NSAlert(); alert.messageText = "Export this Docker image?"; alert.informativeText = "CloudNest will save \(image.id) to a new local backup, then verify size and SHA-256. It will not remove this image, stop containers or copy volumes. Images can contain private data and embedded secrets."
        alert.addButton(withTitle: "Export image"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
        let limits = limits(), request = UUID(); generation = request; bytes = 0; result = nil
        start("Streaming the selected image to private staging…") { [model = self] in
            let driver = try DockerImageBackup.local(protectedRoots: protectedRoots, limits: limits)
            let result = try driver.export(image: image, to: destination) { value in Task { @MainActor [weak model] in if model?.generation == request { model?.bytes = value } } }
            Task { @MainActor [weak model] in model?.result = result }
            return "Local image backup verified. Inspect its manifest before sending it to cloud storage. The image remains in Docker."
        }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Review Docker backup"
        panel.message = "Select a CloudNest Docker image backup containing image.tar and CLOUDNEST_DOCKER.json. Only load images from a source you trust."
        if panel.runModal() == .OK, let url = panel.url {
            do { review = try DockerImageBackup.review(directory: url); message = "Manifest ready for review. The archive will be copied and hash-verified before Docker receives it." }
            catch { self.error = error.localizedDescription }
        }
    }
    func importReviewed(protectedRoots: [URL]) {
        guard let review else { return }
        let alert = NSAlert(); alert.messageText = "Import this verified image into Docker?"
        alert.informativeText = "Image: \(review.manifest.selectedReference)\nID: \(review.manifest.imageID)\n\nOnly continue if you trust this backup. Docker load can restore image tags. No container will be run. Verification requires a temporary copy on the Mac plus a 512 MB safety margin. Cancelling cannot undo layers already accepted by the daemon."
        alert.addButton(withTitle: "Verify and import"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
        let limits = limits()
        start("Verifying a private copy before Docker image load…") {
            let driver = try DockerImageBackup.local(protectedRoots: protectedRoots, limits: limits)
            try driver.importBackup(approved: review)
            return "Docker accepted the archive and the expected image ID was confirmed. No container was created or started."
        }
    }
    func cancel() { message = "Stopping the current CLI operation…"; operation?.cancel() }
}

struct DockerBackupView: View {
    var protectedRoots: [URL] = []
    var archiveBackup: ((URL) -> Void)?
    @StateObject private var model = DockerBackupModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Docker image backups").font(.largeTitle.bold())
            Text("Portable image layers with a verified local manifest. Docker stays under your control.").foregroundStyle(.secondary)
            ProductPanel {
                HStack { Label(model.connectedVersion.map { "Local daemon · \($0)" } ?? "Local daemon unchecked", systemImage: "shippingbox").font(.headline); Spacer(); Button("Check Docker") { model.check(protectedRoots: protectedRoots) } }
                TextField("One local image, for example alpine:latest", text: $model.reference)
                HStack { Button("Resolve image ID") { model.resolve(protectedRoots: protectedRoots) }.disabled(model.reference.isEmpty || model.connectedVersion == nil); if let image = model.image { Text(image.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                HStack { Text(model.destination?.path ?? "Choose a local destination").font(.caption).textSelection(.enabled); Spacer(); Button("Choose destination…", action: model.chooseDestination) }
                Stepper("Maximum image archive: \(model.maximumGB) GB", value: $model.maximumGB, in: 1...100)
                Button("Export selected image…") { model.export(protectedRoots: protectedRoots) }.buttonStyle(.borderedProminent).disabled(model.image == nil || model.destination == nil)
                Text("A new backup folder is published only after save succeeds and its content hash matches. Failed or interrupted staging remains private and is never offered as a completed backup.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            if let result = model.result {
                ProductPanel {
                    Label("Image backup verified", systemImage: "checkmark.seal").font(.headline)
                    Text("\(ByteCountFormatter.string(fromByteCount: result.manifest.bytes, countStyle: .file)) · \(result.manifest.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack { Button("Review manifest") { NSWorkspace.shared.activateFileViewerSelecting([result.manifestURL]) }; Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.directory]) }; if let archiveBackup { Button("Review cloud archive…") { archiveBackup(result.directory) } } }
                }
            }
            ProductPanel {
                Label("Restore an image", systemImage: "arrow.down.doc").font(.headline)
                Button("Choose backup to review…", action: model.chooseImport)
                if let review = model.review {
                    Text(review.manifest.selectedReference).font(.headline)
                    Text(review.manifest.imageID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Archive: \(ByteCountFormatter.string(fromByteCount: review.manifest.bytes, countStyle: .file)). Integrity is checked before import; the manifest is not a signature or proof of trust.").font(.caption).foregroundStyle(.secondary)
                    Button("Verify and import…") { model.importReviewed(protectedRoots: protectedRoots) }.disabled(model.connectedVersion == nil)
                }
            }.disabled(model.busy)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.message).foregroundStyle(.secondary); Spacer(); if model.busy { Button("Cancel", action: model.cancel) } }
            if model.busy, model.bytes > 0 { Text("\(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)) streamed").font(.caption).foregroundStyle(.secondary) }
            Text("Volume and database backups are unsupported here: they require application-consistent exports. CloudNest does not inspect containers, copy Docker’s live disk, start Docker, remove images or run imported images. Navigating away cancels the current operation.").font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { if model.busy { model.cancel() } }
        .alert("Docker image backup", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
