import AppKit
import CloudNestCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor private final class ReleaseUpdateModel: ObservableObject {
  @Published var release: VerifiedRelease?
  @Published var staged: StagedRelease?
  @Published var recoveries: [ReleaseUpdateInstaller.Recovery] = []
  @Published var busy = false
  private var helper: Process?
  private var releaseInstallation: (@MainActor () -> Void)?
  @Published var message =
    "Updates are checked only when you click. No background polling or automatic installation."
  @Published var failure: String?
  private var task: Task<Void, Never>?
  func check(_ configuration: ReleaseUpdateConfiguration, installed: String) {
    run("Checking the signed publisher feed…") {
      let service = ReleaseUpdate(configuration: configuration)
      let worker = Task.detached(priority: .utility) {
        try await service.check(currentVersion: installed)
      }
      let release = try await withTaskCancellationHandler(
        operation: { try await worker.value }, onCancel: { worker.cancel() })
      self.release = release
      self.staged = nil
      self.message =
        release.map {
          "Verified publisher manifest for \($0.manifest.version). Review before downloading."
        } ?? "No newer compatible release was offered by the signed feed."
    }
  }
  func download(_ configuration: ReleaseUpdateConfiguration, installed: String) {
    guard let release else { return }
    let panel = NSAlert()
    panel.messageText = "Download this signed release?"
    panel.informativeText =
      "CloudNest \(release.manifest.version) · \(ByteCountFormatter.string(fromByteCount: release.manifest.bytes, countStyle: .file))\n\nThe artifact will be staged privately and checked against the publisher's signed SHA-256. This step does not install or run it. A signed ZIP can then be verified, installed and relaunched with a retained previous app."
    panel.addButton(withTitle: "Download and verify")
    panel.addButton(withTitle: "Cancel")
    guard panel.runModal() == .alertFirstButtonReturn else { return }
    run("Downloading into private staging and verifying its size and SHA-256…") {
      let service = ReleaseUpdate(configuration: configuration)
      let worker = Task.detached(priority: .utility) {
        let root = try ReleaseUpdate.defaultStagingDirectory()
        return try await service.stage(release, currentVersion: installed, under: root)
      }
      self.staged = try await withTaskCancellationHandler(
        operation: { try await worker.value }, onCancel: { worker.cancel() })
      self.message =
        "Publisher signature, download size and SHA-256 verified. Use Install and relaunch for a signed ZIP. Its extracted app must also pass Developer ID, version and notarization checks."
    }
  }
  func loadRecoveries() async {
    do {
      let worker = Task.detached(priority: .utility) { try ReleaseUpdateInstaller.recoveries() }
      recoveries = try await withTaskCancellationHandler(
        operation: { try await worker.value }, onCancel: { worker.cancel() })
    } catch is CancellationError {} catch {
      failure = "Update recovery could not be inspected. No application was changed."
    }
  }
  func install(
    _ configuration: ReleaseUpdateConfiguration,
    acquire: (@MainActor () -> (@MainActor () -> Void)?)?
  ) {
    guard let staged, let acquire else { return }
    let alert = NSAlert()
    alert.messageText = "Install CloudNest " + staged.release.manifest.version + " and relaunch?"
    alert.informativeText =
      "Save your work first. CloudNest will verify the exact signed ZIP and its app, quit this process, and exchange the application atomically. The previous app is kept privately for recovery. User files, memories and credentials are never rolled back."
    alert.addButton(withTitle: "Verify, install & relaunch")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    handoff(acquire: acquire) {
      let current = Bundle.main.bundleURL
      let worker = Task.detached(priority: .userInitiated) {
        try ReleaseUpdateInstaller.prepare(
          staged: staged, configuration: configuration, currentApp: current)
      }
      let prepared = try await withTaskCancellationHandler(
        operation: { try await worker.value }, onCancel: { worker.cancel() })
      try Task.checkCancellation()
      let starter = Task.detached(priority: .userInitiated) {
        try ReleaseUpdateInstaller.startHelper(prepared, currentApp: current)
      }
      return try await withTaskCancellationHandler(
        operation: { try await starter.value }, onCancel: { starter.cancel() })
    }
  }
  func retry(
    _ recovery: ReleaseUpdateInstaller.Recovery,
    acquire: (@MainActor () -> (@MainActor () -> Void)?)?
  ) {
    guard let acquire else { return }
    let alert = NSAlert()
    alert.messageText = "Retry this verified update?"
    alert.informativeText =
      "CloudNest rechecks the publisher, artifact binding and both apps. Save your work first; the app will quit only after the helper starts."
    alert.addButton(withTitle: "Retry & relaunch")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    handoff(acquire: acquire) {
      let worker = Task.detached(priority: .userInitiated) {
        try ReleaseUpdateInstaller.retry(recovery)
      }
      let prepared = try await withTaskCancellationHandler(
        operation: { try await worker.value }, onCancel: { worker.cancel() })
      try Task.checkCancellation()
      let current = Bundle.main.bundleURL
      let starter = Task.detached(priority: .userInitiated) {
        try ReleaseUpdateInstaller.startHelper(prepared, currentApp: current)
      }
      return try await withTaskCancellationHandler(
        operation: { try await starter.value }, onCancel: { starter.cancel() })
    }
  }
  func rollback(
    _ recovery: ReleaseUpdateInstaller.Recovery,
    acquire: (@MainActor () -> (@MainActor () -> Void)?)?
  ) {
    guard let acquire else { return }
    let alert = NSAlert()
    alert.messageText = "Restore the previous verified CloudNest application?"
    alert.informativeText =
      "This restores application code only. User files, memories, credentials and catalog data are kept as they are. If their format changed, the previous app may require a newer version. Both application copies remain available. Save your work first."
    alert.addButton(withTitle: "Verify previous app & quit")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    handoff(acquire: acquire) {
      let current = Bundle.main.bundleURL
      let worker = Task.detached(priority: .userInitiated) {
        try ReleaseUpdateInstaller.startRollback(recovery, currentApp: current)
      }
      return try await withTaskCancellationHandler(
        operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
  }
  private func handoff(
    acquire: @MainActor () -> (@MainActor () -> Void)?,
    prepare: @escaping @MainActor () async throws -> Process
  ) {
    guard !busy else { return }
    guard let release = acquire() else {
      failure = "Finish the current CloudNest operation before installing an update."
      return
    }
    busy = true
    failure = nil
    message = "Verifying the release and preparing an atomic handoff…"
    releaseInstallation = release
    task = Task { @MainActor [self] in
      do {
        let process = try await prepare()
        if Task.isCancelled {
          if process.isRunning { process.terminate() }
          throw CancellationError()
        }
        helper = process
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.helperEnded() } }
        if !process.isRunning {
          helperEnded()
          return
        }
        message = "Verified helper started. Quitting CloudNest before installation…"
        NSApplication.shared.terminate(nil)
      } catch {
        releaseInstallation?()
        releaseInstallation = nil
        busy = false
        task = nil
        failure = error.localizedDescription
        message =
          "Update preparation stopped. The installed application was not replaced. Review recovery before retrying."
        await loadRecoveries()
      }
    }
  }
  private func helperEnded() {
    // This code runs only if the original app did not quit. The helper will
    // not replace an application while its captured process is still alive.
    helper = nil
    releaseInstallation?()
    releaseInstallation = nil
    busy = false
    task = nil
    message =
      "The helper exited while this app remained open. Review the recovery state before trying again."
    Task { await loadRecoveries() }
  }
  private func run(_ status: String, work: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    failure = nil
    message = status
    task = Task {
      do { try await work() } catch is CancellationError {
        message = "Stopped. No application was installed or replaced."
      } catch {
        failure = error.localizedDescription
        message =
          "Update did not complete. Keep using the installed version; no automatic retry will run."
      }
      busy = false
      task = nil
    }
  }
  func cancel() { task?.cancel() }
}
struct ReleaseUpdateView: View {
  var configuration: ReleaseUpdateConfiguration?
  var installedVersion: String
  var acquireInstallation: (@MainActor () -> (@MainActor () -> Void)?)?
  @StateObject private var model = ReleaseUpdateModel()
  init(
    configuration: ReleaseUpdateConfiguration? = nil,
    installedVersion: String = ReleaseUpdate.installedVersion(),
    acquireInstallation: (@MainActor () -> (@MainActor () -> Void)?)? = nil
  ) {
    self.configuration = configuration
    self.installedVersion = installedVersion
    self.acquireInstallation = acquireInstallation
  }
  var body: some View {
    GroupBox("Signed release updates") {
      VStack(alignment: .leading, spacing: 12) {
        Text("Installed version: \(installedVersion)").font(.callout)
        if let configuration {
          Text(
            "Updates use a pinned publisher key and Developer ID. Installation is user initiated, verifies the exact archive, and keeps a previous app for recovery."
          ).foregroundStyle(.secondary)
          Button("Check for signed update") {
            model.check(configuration, installed: installedVersion)
          }.disabled(model.busy)
          if let release = model.release {
            Text(
              "Version \(release.manifest.version), build \(release.manifest.build) · macOS \(release.manifest.minimumMacOS)+ · \(release.manifest.architectures.joined(separator: ", "))"
            )
            if model.staged == nil {
              Button("Review download…") {
                model.download(configuration, installed: installedVersion)
              }.disabled(model.busy)
            }
          }
          if let staged = model.staged {
            HStack {
              Button("Reveal verified download") {
                NSWorkspace.shared.activateFileViewerSelecting([staged.artifact])
              }
              if staged.release.manifest.assetURL.pathExtension == "zip" {
                Button("Install and relaunch…") {
                  model.install(configuration, acquire: acquireInstallation)
                }.disabled(model.busy || acquireInstallation == nil)
              } else {
                Text(
                  "DMG downloads use manual installation. Signed ZIP updates support verified automatic handoff."
                ).font(.caption)
              }
            }
          }
          if model.busy {
            HStack {
              ProgressView().controlSize(.small)
              Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
            }
          }
          Text(model.message).font(.callout).accessibilityLabel("Update status: " + model.message)
          if let failure = model.failure {
            Text(failure).foregroundStyle(.red).textSelection(.enabled)
          }
        } else {
          Text(
            "Signed updates are unavailable in this preview. A reviewed publisher public key, a valid Developer ID release and a signed feed must be configured before update checks can be enabled."
          ).foregroundStyle(.secondary)
          Text(
            "CloudNest never installs an unsigned update or bypasses Gatekeeper. Developer ID, notarization and real signed-update acceptance are required before public distribution."
          ).font(.caption)
        }
      }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
      ForEach(model.recoveries) { recovery in
        VStack(alignment: .leading, spacing: 8) {
          Text("Previous installation: " + recovery.version).font(.headline)
          Text("Recovery state: " + recovery.phase).font(.caption)
          HStack {
            Button("Reveal retained files") {
              NSWorkspace.shared.activateFileViewerSelecting([recovery.directory])
            }
            if recovery.canRetry {
              Button("Retry update…") { model.retry(recovery, acquire: acquireInstallation) }
                .disabled(model.busy || acquireInstallation == nil)
            }
            if recovery.canRollback {
              Button("Restore previous app…") {
                model.rollback(recovery, acquire: acquireInstallation)
              }.disabled(model.busy || acquireInstallation == nil)
            }
          }
        }.padding(.vertical, 8)
      }
    }.task { await model.loadRecoveries() }.onDisappear { model.cancel() }
  }
}

@MainActor private final class PublisherSettingsModel: ObservableObject {
  @Published var configuration: ReleaseUpdateConfiguration?
  @Published var failure: String?
  func load() {
    do { configuration = try ReleaseUpdateConfiguration.bundled() } catch {
      failure = "This build's publisher metadata is invalid. Update checks remain disabled."
    }
  }
}
struct ReleasePublisherSettingsView: View {
  var acquireInstallation: (@MainActor () -> (@MainActor () -> Void)?)?
  @StateObject private var model = PublisherSettingsModel()
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ReleaseUpdateView(
        configuration: model.configuration, acquireInstallation: acquireInstallation)
      if let failure = model.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
    }.task { model.load() }
  }
}
