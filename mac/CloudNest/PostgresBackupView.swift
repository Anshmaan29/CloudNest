import SwiftUI
import AppKit
import CloudNestCore

@MainActor private final class PostgresBackupModel: ObservableObject {
    @Published var reference = "" { didSet { if reference != oldValue { container = nil } } }
    @Published var database = "appdata"
    @Published var role = "postgres"
    @Published var container: ResolvedPostgresContainer?
    @Published var destination: URL?
    @Published var result: PostgresBackupResult?
    @Published var review: PostgresBackupReview?
    @Published var restored: PostgresRestoreResult?
    @Published var recoveryDirectory: URL?
    @Published var maximumGB = 20
    @Published var busy = false
    @Published var bytes: Int64 = 0
    @Published var message = "Select one already-running local PostgreSQL container. CloudNest never starts Docker or copies database volumes."
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private func driver(_ protected: [URL]) throws -> PostgresBackup { var limits = PostgresBackupLimits(); limits.maximumBytes = Int64(maximumGB) * 1_000_000_000; return try PostgresBackup.local(protectedRoots: protected, limits: limits) }
    private func run(_ label: String, work: @escaping @Sendable (UUID) throws -> String) {
        guard !busy else { return }; busy = true; message = label; let request = UUID(); generation = request
        task = Task {
            let job = Task.detached(priority: .utility) { try work(request) }
            do { message = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }) }
            catch let failure as PostgresRestoreFailure { recoveryDirectory = failure.recoveryDirectory; message = "Restore is incomplete or uncertain. Inspect the planned database and private recovery records; it is never dropped automatically."; error = failure.localizedDescription }
            catch is CancellationError { message = "Stopped waiting. Private partial staging may remain. The container command is time bounded and may continue until its timeout." }
            catch { self.error = error.localizedDescription; message = "Operation did not complete. Retain and inspect staging; no existing database is automatically changed or removed by cleanup." }
            busy = false; task = nil
        }
    }
    func resolve(_ protected: [URL]) {
        do {
            let driver = try driver(protected), selected = reference
            run("Checking only the selected container…") { [model = self] request in
                let resolved = try driver.resolve(container: selected)
                Task { @MainActor [weak model] in if model?.generation == request && model?.reference == selected { model?.container = resolved } }
                return "Selected container is running and pinned by immutable ID. Database authentication must use its local peer/trust configuration."
            }
        } catch { self.error = error.localizedDescription }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Choose backup destination"
        panel.message = "Choose a local folder outside protected, cloud and repository paths. PostgreSQL dumps can contain private application data."
        if panel.runModal() == .OK { destination = panel.url }
    }
    func dump(_ protected: [URL]) {
        guard let container, let destination else { return }
        let selectedDatabase = database, selectedRole = role
        let alert = NSAlert(); alert.messageText = "Export this PostgreSQL database?"
        alert.informativeText = "Database: \(selectedDatabase)\nRole: \(selectedRole)\nContainer: \(container.id)\n\nCloudNest will run a consistent pg_dump in custom format and verify it with pg_restore --list. Only local Unix-socket peer/trust authentication is supported. Original database data and volumes are retained."
        alert.addButton(withTitle: "Export logical backup"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let driver = try driver(protected); bytes = 0; result = nil
            run("Streaming a private PostgreSQL logical dump…") { [model = self] request in
                let result = try driver.dump(container: container, database: selectedDatabase, role: selectedRole, to: destination) { count in Task { @MainActor [weak model] in if model?.generation == request { model?.bytes = count } } }
                Task { @MainActor [weak model] in if model?.generation == request { model?.result = result } }
                return "Logical dump verified by size, SHA-256 and pg_restore --list. Review the local manifest before cloud archiving."
            }
        } catch { self.error = error.localizedDescription }
    }
    func chooseReview() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "Review PostgreSQL backup"
        if panel.runModal() == .OK, let url = panel.url { do { review = try PostgresBackup.review(directory: url) } catch { self.error = error.localizedDescription } }
    }
    func restore(_ protected: [URL]) {
        guard let container, let review else { return }
        do {
            let driver = try driver(protected), plan = try driver.planRestore(approved: review, container: container, role: role)
            let alert = NSAlert(); alert.messageText = "Restore trusted SQL into a NEW database?"
            alert.informativeText = "New database: \(plan.databaseName)\nRole: \(plan.role)\nContainer: \(container.id)\n\nRestore can execute arbitrary SQL with this role's permissions. A privileged role may affect resources beyond the new database. Only continue if you trust the archive and selected container. CloudNest will not drop or overwrite an existing database. Failed or cancelled restoration can leave the new database for manual review."
            alert.addButton(withTitle: "Restore trusted archive"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
            run("Verifying archive before creating \(plan.databaseName)…") { [model = self] request in
                let result = try driver.restore(plan: plan)
                Task { @MainActor [weak model] in if model?.generation == request { model?.restored = result; model?.recoveryDirectory = result.recoveryDirectory } }
                return "pg_restore completed in the new database \(result.databaseName). Validate it using your application's own checks."
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancel() { task?.cancel() }
}

struct PostgresBackupView: View {
    var protectedRoots: [URL] = []
    var archiveBackup: ((URL) -> Void)?
    @StateObject private var model = PostgresBackupModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("PostgreSQL logical backups").font(.largeTitle.bold())
            Text("One running local container, consistent pg_dump exports, and trusted restoration into a new database.").foregroundStyle(.secondary)
            ProductPanel {
                TextField("Container name or immutable ID", text: $model.reference)
                HStack { Button("Check selected container") { model.resolve(protectedRoots) }.disabled(model.reference.isEmpty); if let container = model.container { Text(container.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                TextField("Source database", text: $model.database); TextField("Existing database role", text: $model.role)
                HStack { Text(model.destination?.path ?? "No backup destination selected").font(.caption).textSelection(.enabled); Spacer(); Button("Choose destination…", action: model.chooseDestination) }
                Stepper("Maximum dump: \(model.maximumGB) GB", value: $model.maximumGB, in: 1...100)
                Button("Review logical export…") { model.dump(protectedRoots) }.buttonStyle(.borderedProminent).disabled(model.container == nil || model.destination == nil)
                Text("Requires pg_dump, pg_restore, createdb, /usr/bin/env and compatible /usr/bin/timeout in the selected container. Passwords, remote PostgreSQL connections and raw volume copying are unsupported.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            if let result = model.result {
                ProductPanel {
                    Label("Verified custom-format dump", systemImage: "checkmark.seal").font(.headline)
                    Text("\(result.manifest.database) · \(ByteCountFormatter.string(fromByteCount: result.manifest.bytes, countStyle: .file))").font(.caption)
                    HStack { Button("Review manifest") { NSWorkspace.shared.activateFileViewerSelecting([result.manifestURL]) }; if let archiveBackup { Button("Review cloud archive…") { archiveBackup(result.directory) } } }
                }
            }
            ProductPanel {
                Label("Restore only a trusted backup", systemImage: "exclamationmark.shield").font(.headline)
                Button("Choose backup to review…", action: model.chooseReview)
                if let review = model.review { Text("\(review.manifest.database) · \(review.manifest.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled); Button("Review NEW database restore…") { model.restore(protectedRoots) }.disabled(model.container == nil) }
                Text("Archive SQL executes with the selected database role. Remote AI clients receive no restore tool. Review and approve restoration here.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            HStack { if model.busy { ProgressView().controlSize(.small); Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)); Button("Cancel", action: model.cancel) }; Text(model.message).font(.caption).foregroundStyle(.secondary) }
            if let recovery = model.recoveryDirectory { Button("Inspect private restore records") { NSWorkspace.shared.activateFileViewerSelecting([recovery]) } }
        }
        .alert("PostgreSQL backup", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
