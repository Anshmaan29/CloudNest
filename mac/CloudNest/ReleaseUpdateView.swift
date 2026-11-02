import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloudNestCore

@MainActor private final class ReleaseUpdateModel: ObservableObject {
    @Published var release: VerifiedRelease?
    @Published var staged: StagedRelease?
    @Published var busy = false
    @Published var message = "Updates are checked only when you click. No background polling or automatic installation."
    @Published var failure: String?
    private var task: Task<Void, Never>?
    func check(_ configuration: ReleaseUpdateConfiguration, installed: String) {
        run("Checking the signed publisher feed…") {
            let service = ReleaseUpdate(configuration: configuration)
            let worker = Task.detached(priority: .utility) { try await service.check(currentVersion: installed) }
            let release = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            self.release = release; self.staged = nil
            self.message = release.map { "Verified publisher manifest for \($0.manifest.version). Review before downloading." } ?? "No newer compatible release was offered by the signed feed."
        }
    }
    func download(_ configuration: ReleaseUpdateConfiguration, installed: String) {
        guard let release else { return }
        let panel = NSAlert(); panel.messageText = "Download this signed release?"
        panel.informativeText = "CloudNest \(release.manifest.version) · \(ByteCountFormatter.string(fromByteCount: release.manifest.bytes, countStyle: .file))\n\nThe artifact will be staged privately and checked against the publisher's signed SHA-256. This does not install or run it. Extract it manually, then validate the CloudNest app before installation."
        panel.addButton(withTitle: "Download and verify"); panel.addButton(withTitle: "Cancel")
        guard panel.runModal() == .alertFirstButtonReturn else { return }
        run("Downloading into private staging and verifying its size and SHA-256…") {
            let service = ReleaseUpdate(configuration: configuration)
            let worker = Task.detached(priority: .utility) {
                let root = try ReleaseUpdate.defaultStagingDirectory()
                return try await service.stage(release, currentVersion: installed, under: root)
            }
            self.staged = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            self.message = "Publisher signature, download size and SHA-256 verified. Installation is still blocked until the extracted app passes Developer ID and notarization checks."
        }
    }
    func validate(_ configuration: ReleaseUpdateConfiguration, installed: String) {
        guard let staged else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowedContentTypes = [.applicationBundle]; panel.prompt = "Validate extracted CloudNest app"
        panel.message = "Select the extracted app. CloudNest checks its publisher, version, build and current Gatekeeper notarization status. It will not install or execute it."
        guard panel.runModal() == .OK, let app = panel.url else { return }
        run("Validating the extracted app against the pinned Developer ID and Apple's notarization policy…") {
            let service = ReleaseUpdate(configuration: configuration)
            let worker = Task.detached(priority: .utility) { try await service.validateApplication(app, staged: staged, currentVersion: installed) }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            self.message = "Selected app passed the pinned Developer ID, version/build and notarized Gatekeeper assessment. Automatic installation is unavailable; close CloudNest and use your normal manual installation procedure."
        }
    }
    private func run(_ status: String, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; failure = nil; message = status
        task = Task {
            do { try await work() }
            catch is CancellationError { message = "Stopped. No application was installed or replaced." }
            catch { failure = error.localizedDescription; message = "Update did not complete. Keep using the installed version; no automatic retry will run." }
            busy = false; task = nil
        }
    }
    func cancel() { task?.cancel() }
}
struct ReleaseUpdateView: View {
    var configuration: ReleaseUpdateConfiguration?
    var installedVersion: String
    @StateObject private var model = ReleaseUpdateModel()
    init(configuration: ReleaseUpdateConfiguration? = nil, installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0") { self.configuration = configuration; self.installedVersion = installedVersion }
    var body: some View {
        GroupBox("Signed release updates") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Installed version: \(installedVersion)").font(.callout)
                if let configuration {
                    Text("Manual checks use a pinned publisher key and Developer ID. Downloads are verified privately; installation and app replacement are never automatic.").foregroundStyle(.secondary)
                    Button("Check for signed update") { model.check(configuration, installed: installedVersion) }.disabled(model.busy)
                    if let release = model.release {
                        Text("Version \(release.manifest.version), build \(release.manifest.build) · macOS \(release.manifest.minimumMacOS)+ · \(release.manifest.architectures.joined(separator: ", "))")
                        if model.staged == nil { Button("Review download…") { model.download(configuration, installed: installedVersion) }.disabled(model.busy) }
                    }
                    if let staged = model.staged {
                        HStack {
                            Button("Reveal verified download") { NSWorkspace.shared.activateFileViewerSelecting([staged.artifact]) }
                            Button("Validate extracted app…") { model.validate(configuration, installed: installedVersion) }.disabled(model.busy)
                        }
                    }
                    if model.busy { HStack { ProgressView().controlSize(.small); Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction) } }
                    Text(model.message).font(.callout).accessibilityLabel("Update status: " + model.message)
                    if let failure = model.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                } else {
                    Text("Signed updates are unavailable in this preview. A reviewed publisher public key, a valid Developer ID release and a signed feed must be configured before update checks can be enabled.").foregroundStyle(.secondary)
                    Text("Automatic installation remains a release gate. CloudNest will never install an unsigned update or bypass Gatekeeper.").font(.caption)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.onDisappear { model.cancel() }
    }
}

@MainActor private final class PublisherSettingsModel: ObservableObject {
    @Published var configuration: ReleaseUpdateConfiguration?
    @Published var failure: String?
    func load() {
        do { configuration = try ReleaseUpdateConfiguration.bundled() }
        catch { failure = "This build's publisher metadata is invalid. Update checks remain disabled." }
    }
}
struct ReleasePublisherSettingsView: View {
    @StateObject private var model = PublisherSettingsModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReleaseUpdateView(configuration: model.configuration)
            if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }.task { model.load() }
    }
}
