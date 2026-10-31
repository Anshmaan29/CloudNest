import SwiftUI
import AppKit
import CloudNestCore

@MainActor
private final class OnboardingSession: ObservableObject {
    @Published var progress: OnboardingProgress {
        didSet { do { try progress.save(to: .standard) } catch { self.error = "Setup could not be saved. Existing archives and credentials are unchanged." } }
    }
    @Published var showBrain = false
    @Published var goal = ""
    @Published var nextAction = ""
    @Published var copied = false
    @Published var hoveredStep: OnboardingStep?
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var publicClient: BundledGoogleClient?
    @Published var publicClientError: String?
    @Published var clientChecked = false
    @Published var hasSavedClient = false
    @Published var brainConfigured = false
    @Published var archiveJob: ArchiveJob?
    @Published var restoreValidated = false
    @Published var localStateLoading = true
    private var task: Task<Void, Never>?
    private let oauth = GoogleOAuth()
    init() {
        do { progress = try OnboardingProgress.load(from: .standard) }
        catch { progress = OnboardingProgress(); self.error = "The saved setup checkpoint could not be read. Review these steps again; your Keychain and archive catalog have been retained." }
        do { publicClient = try BundledGoogleClient.load() }
        catch { publicClientError = "This build's public Google client metadata is invalid. Use a dedicated Desktop client or ask the publisher for a corrected build." }
    }
    private func directory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CloudNest", isDirectory: true)
    }
    private func catalog() async throws -> Catalog {
        let directory = try directory()
        return try await Task.detached(priority: .utility) { try Catalog(directory: directory) }.value
    }
    func refreshLocal() async {
        guard !busy else { return }
        localStateLoading = true
        defer { localStateLoading = false }
        do { hasSavedClient = try await BundledGoogleClient.hasSavedClient(); clientChecked = true }
        catch { clientChecked = true; self.error = "Saved Google configuration could not be read. Unlock Keychain or import your original Desktop client; no credential was replaced." }
        do { brainConfigured = try await KeychainStore().read("brain-owner-connection") != nil }
        catch { brainConfigured = false }
        archiveJob = nil; restoreValidated = false
        guard let id = progress.archiveJobID else { return }
        do {
            let db = try await catalog(), job = try await db.job(id)
            archiveJob = job
            if let proof = progress.restoreProof, proof.jobID == id {
                let roundTrip = OnboardingRoundTrip(catalog: db, remote: DriveClient(oauth: oauth))
                restoreValidated = (try? await roundTrip.validate(proof)) == true
            }
        } catch { self.error = "The saved introductory archive is unavailable. Select another verified catalog archive or archive a new file. No original was removed." }
    }
    func canContinue(_ step: OnboardingStep, model: AppModel) -> Bool {
        guard !busy, !model.busy, !localStateLoading else { return false }
        switch step {
        case .googleDrive: return model.authorizationChecked && model.connected
        case .folders: return !model.approvedFolders.isEmpty
        case .safety: return progress.safetyReviewed
        case .archive: return archiveJob?.state == .verified
        case .restore: return restoreValidated
        default: return true
        }
    }
    func usePublicClient(model: AppModel) {
        guard let config = publicClient else { return }
        if hasSavedClient {
            let alert = NSAlert(); alert.messageText = "Replace your saved Storage client?"
            alert.informativeText = "A different Google project may not access archives made with your existing client. The current grant will be disconnected. Keep your original Storage client available."
            alert.addButton(withTitle: "Use release client"); alert.addButton(withTitle: "Keep existing client")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        run(model, "Waiting for Google sign-in in your browser…") {
            try await config.install(into: self.oauth, stagingDirectory: self.directory().appendingPathComponent("PublicClientStaging", isDirectory: true))
            try await self.oauth.signIn()
            self.status = "Google sign-in completed."
        }
    }
    func signIn(model: AppModel) {
        run(model, "Waiting for Google sign-in in your browser…") {
            try await self.oauth.signIn()
            self.status = "Google sign-in completed."
        }
    }
    private func workflow(model: AppModel, catalog: Catalog) throws -> OnboardingRoundTrip {
        let raw = DriveClient(oauth: oauth)
        let remote: any ArchiveRemote
        if model.transferPolicy.enabled {
            let environment = SystemTransferEnvironment()
            remote = try PolicyArchiveRemote(remote: raw, policy: model.transferPolicy, environment: { try await environment.current() })
        } else { remote = raw }
        return OnboardingRoundTrip(catalog: catalog, remote: remote, safety: FileSafety(protectedRoots: model.protectedFolders))
    }
    func chooseArchive(model: AppModel) {
        guard !model.busy, !busy, model.connected else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.directoryURL = model.approvedFolders.first; panel.prompt = "Review this file"
        panel.message = "Choose a small disposable file inside an approved folder. CloudNest will upload and verify it; the original stays exactly where it is."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        guard model.approvedFolders.contains(where: { FileSafety.contains($0, source) }) else { error = "This file is outside your approved folders. Approve its folder in step 3 first."; return }
        let confirmation = NSAlert(); confirmation.messageText = "Archive \(source.lastPathComponent)?"
        confirmation.informativeText = "This uploads the selected file and its recovery manifest to your Google Drive. No original will be moved or deleted."
        confirmation.addButton(withTitle: "Archive & verify"); confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        let approved = model.approvedFolders
        run(model, "Uploading the selected file and verifying its recovery manifest…") {
            let db = try await self.catalog(), flow = try self.workflow(model: model, catalog: db)
            do {
                let job = try await flow.archive(source: source, approvedRoots: approved, onEnqueued: { job in
                    await MainActor.run { self.progress.selectedArchive(job.id); self.archiveJob = job; self.restoreValidated = false }
                })
                self.select(job); self.status = "Archive and recovery manifest verified. Original retained."
                await self.record(StorageActivity(kind: .archiveVerified, title: job.source.lastPathComponent, jobID: job.id, bytes: job.snapshot.identity.size), deduplicationKey: "verified-" + job.id.uuidString)
            } catch {
                if let id = await flow.lastEnqueuedJobID { self.progress.selectedArchive(id); self.archiveJob = try? await db.job(id) }
                throw error
            }
        }
    }
    func select(_ job: ArchiveJob) {
        progress.selectedArchive(job.id); archiveJob = job; restoreValidated = false
    }
    func resumeArchive(model: AppModel) {
        guard let id = progress.archiveJobID, model.connected else { return }
        run(model, "Resuming the saved archive and checking its integrity…") {
            let db = try await self.catalog(), flow = try self.workflow(model: model, catalog: db)
            let job = try await flow.resume(id, approvedRoots: model.approvedFolders)
            self.select(job); self.status = "Archive and recovery manifest verified. Original retained."
            await self.record(StorageActivity(kind: .archiveVerified, title: job.source.lastPathComponent, jobID: job.id, bytes: job.snapshot.identity.size), deduplicationKey: "verified-" + job.id.uuidString)
        }
    }
    func restore(model: AppModel) {
        guard let job = archiveJob, job.state == .verified, model.connected else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Restore here"; panel.message = "Choose a different folder for \(job.source.lastPathComponent). An existing file is never overwritten. This downloads your real archive and compares SHA-256 and size."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        run(model, "Downloading the archive and verifying the restored bytes…") {
            let db = try await self.catalog(), flow = try self.workflow(model: model, catalog: db)
            let proof = try await flow.restore(job.id, destination: destination)
            self.progress.restoreProof = proof; self.restoreValidated = true
            await self.record(StorageActivity(kind: .restored, title: job.source.lastPathComponent, detail: "Introductory restore: SHA-256 and size matched the verified archive.", jobID: job.id, bytes: proof.bytes))
            self.status = "Restored file verified: SHA-256 and size match. Both copies are retained."
        }
    }
    private func record(_ event: StorageActivity, deduplicationKey: String? = nil) async {
        do { let ledger = try ActivityLedger(directory: directory()); try await ledger.append(event, deduplicationKey: deduplicationKey) }
        catch { self.error = "Content verification succeeded, but Activity history could not be updated. The archive catalog and restore proof retain their verified result." }
    }
    func cancel() { task?.cancel() }
    private func run(_ model: AppModel, _ message: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !model.busy else { return }
        busy = true; model.busy = true; error = nil; status = message
        task = Task {
            do { try await operation() }
            catch is CancellationError { status = "Paused. Your original is retained. Resume the catalog job when ready." }
            catch { self.error = error.localizedDescription; status = "The operation did not finish. No original was removed." }
            await model.refresh()
            model.busy = false; busy = false; task = nil
            await refreshLocal()
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @StateObject private var session = OnboardingSession()
    @FocusState private var goalFocused: Bool
    @AccessibilityFocusState private var headingFocused: Bool
    private var step: OnboardingStep { session.progress.step }
    private var blocked: Bool { model.busy || session.busy }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.padding(24)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    if geometry.size.width >= 800 { sidebar.frame(width: 205); Divider() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if geometry.size.width < 800 { compactNavigation }
                            VStack(alignment: .leading, spacing: 7) {
                                Text(step.title).font(.system(size: 29, weight: .semibold)).accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                                Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            content
                            operationStatus
                        }.padding(28).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
                Divider()
                footer.padding(.horizontal, 24).padding(.vertical, 18)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 640, idealWidth: 960, minHeight: 620, idealHeight: 730)
        .task { await session.refreshLocal() }
        .onChange(of: model.busy) { _, busy in if !busy { Task { await session.refreshLocal() } } }
        .onChange(of: step) { _, _ in headingFocused = true }
        .onChange(of: session.goal) { _, _ in session.copied = false }
        .onChange(of: session.nextAction) { _, _ in session.copied = false }
        .sheet(isPresented: $session.showBrain, onDismiss: { Task { await session.refreshLocal() } }) {
            VStack(spacing: 0) {
                HStack { Text("Optional self-hosted Brain").font(.headline); Spacer(); Button("Done") { session.showBrain = false }.keyboardShortcut(.cancelAction) }.padding(18)
                Divider(); NativeBrainView()
            }.frame(minWidth: 780, idealWidth: 920, minHeight: 620)
        }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cloud.fill").font(.system(size: 29)).foregroundStyle(.indigo).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) { Text("CloudNest setup").font(.headline); Text("A safe round trip, before you reclaim space.").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary).accessibilityLabel("Setup step \(step.rawValue + 1) of 8")
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                Button { session.progress.visit(item) } label: {
                    HStack(spacing: 10) { Image(systemName: item.symbol).frame(width: 19); Text(item.title).font(.callout); Spacer() }
                        .padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
                        .background(step == item ? Color.indigo.opacity(0.12) : (session.hoveredStep == item ? Color.primary.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(blocked || item.rawValue > session.progress.furthestStep.rawValue)
                    .onHover { hovering in session.hoveredStep = hovering && item.rawValue <= session.progress.furthestStep.rawValue ? item : nil }
                    .accessibilityLabel("\(item.title)\(step == item ? ", current step" : "")")
                    .help(item.rawValue > session.progress.furthestStep.rawValue ? "Complete the preceding steps first" : "Review this setup step")
            }
            Spacer()
            Label("Originals stay local", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary).padding(10)
        }.padding(14)
    }
    private var compactNavigation: some View {
        Picker("Review a setup step", selection: Binding(get: { step }, set: { session.progress.visit($0) })) {
            ForEach(OnboardingStep.allCases.filter { $0.rawValue <= session.progress.furthestStep.rawValue }, id: \.rawValue) { Text($0.title).tag($0) }
        }.disabled(blocked)
    }
    private var subtitle: String {
        switch step {
        case .welcome: "Make room for what comes next, while keeping a way back."
        case .googleDrive: "Your archive lives in your own Google Drive. You approve Google's permissions in your browser."
        case .folders: "You choose the boundaries. CloudNest never needs a whole-disk scan."
        case .safety: "Verification comes first. Cleanup always needs a separate decision."
        case .brain: "Keep useful context across assistants. Storage works even when Brain is skipped or offline."
        case .assistants: "Choose a connection your assistant supports, or carry a context note yourself."
        case .archive: "Start with a small disposable file. This uploads a real archive and retains the original."
        case .restore: "Bring that file back into a new location and verify the restored content."
        }
    }
    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .googleDrive: google
        case .folders: folders
        case .safety: safety
        case .brain: brain
        case .assistants: assistants
        case .archive: archive
        case .restore: restore
        }
    }
    private var welcome: some View {
        VStack(spacing: 18) {
            ProductPanel {
                Label("Approve → archive → verify → restore", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                Text("These eight steps finish with a real recovery check. Setup never enables cleanup, background scans, login startup, or notifications automatically. Existing preferences stay in effect.")
            }
            ProductPanel {
                assurance("Only folders you approve", "Protected folders and built-in security exclusions still apply.", "folder.badge.checkmark")
                Divider()
                assurance("A portable recovery manifest", "Restore your archive without relying on this Mac's original catalog.", "doc.badge.arrow.up")
                Divider()
                assurance("Storage and Brain are independent", "No model download or paid AI API is needed for file archiving.", "externaldrive")
            }
        }
    }
    private var google: some View {
        VStack(spacing: 18) {
            ProductPanel {
                Label(model.connected ? "Saved Storage authorization is available" : "Connect Google Drive", systemImage: model.connected ? "checkmark.circle.fill" : "person.crop.circle").font(.headline)
                if !model.authorizationChecked || !session.clientChecked { HStack { ProgressView().controlSize(.small); Text("Checking saved Keychain configuration…").font(.callout) } }
                Text("CloudNest requests drive.file: access to files created by or opened with this Google app. It does not request access to everything in Drive. Sign-in uses PKCE in your system browser; tokens stay in Keychain.").font(.callout)
                if session.hasSavedClient {
                    Button(model.connected ? "Sign in again with saved client" : "Sign in with saved Storage client") { session.signIn(model: model) }.disabled(blocked)
                    Text("Your existing client is preserved. Keep using its Google project to access archives made with it. A saved grant can still expire or be revoked; reconnect if a transfer reports an authorization failure.").font(.caption).foregroundStyle(.secondary)
                }
                if session.publicClient != nil {
                    Button("Sign in with this build's Google client") { session.usePublicClient(model: model) }.buttonStyle(.borderedProminent).disabled(blocked)
                } else {
                    Button("Sign in with CloudNest's public Google client") {}.disabled(true)
                        .help("The publisher has not supplied a public Desktop OAuth client for this build.")
                    Text(session.publicClientError ?? "Public sign-in is not configured in this build. The publisher must supply an approved release client before this can be a consumer one-click flow.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProductPanel {
                Text("Advanced: bring your own Desktop client").font(.headline)
                Text("Import the Desktop OAuth JSON from a dedicated Storage project, then sign in. Never import your Brain client as a replacement for an existing Storage client.").font(.callout)
                HStack { Button("Import Desktop OAuth JSON…", action: model.importOAuth).disabled(blocked); Link("Create a Desktop client", destination: URL(string: "https://console.cloud.google.com/auth/clients")!) }
                Text("Importing a valid replacement disconnects the old grant after confirmation. An invalid import leaves it intact.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var folders: some View {
        ProductPanel {
            Text("Approved scan folders").font(.headline)
            if model.approvedFolders.isEmpty { Label("No folder approved yet", systemImage: "folder").foregroundStyle(.secondary); Text("Choose a small, local test folder first. The selection dialog is your approval to inspect that folder.").font(.callout) }
            ForEach(model.approvedFolders, id: \.path) { url in
                HStack { VStack(alignment: .leading, spacing: 3) { Text(url.lastPathComponent).font(.callout.bold()); Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }; Spacer(); Button("Forget") { model.forgetApprovedFolder(url) }.disabled(blocked) }; Divider()
            }
            Button("Approve a folder & analyze…", action: model.addApprovedFolder).disabled(blocked)
            Text("Analysis changes no files and starts no upload. Repositories, active databases, system paths, cloud placeholders and protected folders remain excluded. You can forget an approval later.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var safety: some View {
        VStack(spacing: 18) {
            ProductPanel {
                assurance("Originals stay until you approve cleanup", "Archive verification does not authorize removal. Managed recovery retains a local copy before a second removal approval.", "checkmark.shield")
                Button("Protect a folder…", action: model.protectFolder).disabled(blocked)
                Text("\(model.protectedFolders.count) explicitly protected folders. Built-in system and credential exclusions are always active.").font(.caption).foregroundStyle(.secondary)
                Toggle("I understand that archiving and cleanup are separate approvals", isOn: $session.progress.safetyReviewed).disabled(blocked)
            }
            ProductPanel {
                Text("Optional transfer preferences").font(.headline)
                Toggle("Apply network and power rules", isOn: $model.transferPolicy.enabled)
                Toggle("Require external power", isOn: $model.transferPolicy.requireExternalPower).disabled(!model.transferPolicy.enabled)
                Toggle("Pause in Low Power Mode", isOn: $model.transferPolicy.pauseInLowPowerMode).disabled(!model.transferPolicy.enabled)
                Toggle("Allow networks marked expensive", isOn: $model.transferPolicy.allowExpensiveNetworks).disabled(!model.transferPolicy.enabled)
                Text("These controls save real transfer settings. Scheduled scans, login startup and notifications stay under your separate Settings controls.").font(.caption).foregroundStyle(.secondary)
            }.disabled(blocked)
        }
    }
    private var brain: some View {
        ProductPanel {
            Label(session.brainConfigured ? "A Brain connection is saved locally" : "Brain is optional", systemImage: "brain").font(.headline)
            Text("Connect a self-hosted Brain origin and its dedicated owner credential using the existing Brain setup panel. Saving a connection does not prove that its server is online. Storage does not use that credential.")
            Button(session.brainConfigured ? "Review Brain connection…" : "Configure self-hosted Brain…") { session.showBrain = true }.disabled(blocked)
            Text("Brain needs its own server-side Google authorization. Never paste a Google refresh token or Storage credential into an AI assistant.").font(.caption).foregroundStyle(.secondary)
            Button("Skip Brain and continue") { session.progress.brainSkipped = true; session.progress.advance() }.disabled(blocked)
        }
    }
    private var assistants: some View {
        VStack(spacing: 18) {
            ProductPanel {
                Text("Connect only where supported").font(.headline)
                Text("The MCP SDK and Codex CLI were verified for this version. Hosted ChatGPT, Claude and Gemini connections still need client-specific validation; setup does not claim they are connected.")
                Button("Review Brain client setup…") { session.showBrain = true }.disabled(blocked)
                Text("The Brain console provides scoped client setup. A connector's availability depends on the assistant and account. No assistant receives files or a credential from this wizard.").font(.caption).foregroundStyle(.secondary)
            }
            ProductPanel {
                Text("A context note works anywhere").font(.headline)
                TextField("What are you working on?", text: $session.goal).textFieldStyle(.roundedBorder).focused($goalFocused)
                TextField("What should happen next?", text: $session.nextAction).textFieldStyle(.roundedBorder)
                Button(session.copied ? "Context note session.copied" : "Copy context note") {
                    let note = "Project: \(session.goal.trimmingCharacters(in: .whitespacesAndNewlines))\nNext action: \(session.nextAction.trimmingCharacters(in: .whitespacesAndNewlines))\nAsk before taking actions or accessing additional files."
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note, forType: .string); session.copied = true
                }.disabled(session.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Only the text you enter is session.copied. Review it before pasting into your assistant. For saved project memories, use Brain's context or handoff tools when available.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var archive: some View {
        VStack(spacing: 18) {
            ProductPanel {
                Text("Upload one file. Keep the original.").font(.headline)
                Text("Select a small file from your approved folders. A verified catalog entry requires matching remote SHA-256 and size plus a verified recovery manifest.")
                Button("Choose a file to archive…") { session.chooseArchive(model: model) }.buttonStyle(.borderedProminent).disabled(blocked || !model.connected || model.approvedFolders.isEmpty)
                if !model.connected { Text("Google authorization is unavailable. Return to Google Drive to sign in; Brain is not required.").font(.caption).foregroundStyle(.orange) }
                if let job = session.archiveJob {
                    Divider(); jobSummary(job)
                    if job.state != .verified { Button("Resume saved archive") { session.resumeArchive(model: model) }.disabled(blocked || !model.connected) }
                }
                let existing = model.jobs.filter { $0.state == .verified && $0.folderArchiveID == nil }
                if !existing.isEmpty {
                    Menu("Use an existing verified catalog archive") {
                        ForEach(Array(existing.prefix(40))) { job in Button(job.source.lastPathComponent) { session.select(job) } }
                    }.disabled(blocked)
                }
                Text("No setup action moves, trashes or removes the original. Failed uploads remain resumable in Archive Library.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var restore: some View {
        ProductPanel {
            if let job = session.archiveJob, job.state == .verified {
                jobSummary(job)
                Text("Choose a new destination. CloudNest downloads this archive, checks SHA-256 and size, then installs it without overwriting an existing file.")
                Button("Choose destination & verify restore…") { session.restore(model: model) }.buttonStyle(.borderedProminent).disabled(blocked || !model.connected)
                if !model.connected { Text("Reconnect Google Drive to download the archive. Brain can remain offline.").font(.caption).foregroundStyle(.orange) }
                if let proof = session.progress.restoreProof {
                    Divider()
                    Label(session.restoreValidated ? "Restored content matches the verified archive" : "The previous restored file needs to be verified again", systemImage: session.restoreValidated ? "checkmark.seal.fill" : "exclamationmark.circle").foregroundStyle(session.restoreValidated ? Color.green : Color.orange)
                    Text(proof.restoredURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if session.restoreValidated { Text("\(model.format(proof.bytes)) · SHA-256 and size match · Original retained").font(.caption).foregroundStyle(.secondary); Button("Show restored file") { NSWorkspace.shared.activateFileViewerSelecting([proof.restoredURL]) }.disabled(blocked) }
                    else { Text("It may have moved or changed. Restore into another empty destination to finish setup; no previous copy is overwritten.").font(.caption).foregroundStyle(.secondary) }
                }
            } else { Text("Choose a verified archive in the preceding step before testing recovery.") }
            Text("Cleanup is not part of this introduction. When you later choose to reclaim space, CloudNest asks for separate approval.").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var operationStatus: some View {
        if session.busy || model.busy || session.localStateLoading {
            HStack(alignment: .top) { ProgressView().controlSize(.small); Text(session.busy ? session.status : (model.busy ? model.message : "Reading saved setup and catalog state…")).font(.callout); Spacer(); if session.busy { Button("Pause", action: session.cancel) } else if model.canCancel { Button("Pause", action: model.cancelOperation) } }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).accessibilityElement(children: .contain)
        } else if !session.status.isEmpty { Text(session.status).font(.callout).foregroundStyle(.secondary).accessibilityLabel(session.status) }
        if let error = session.error ?? model.errorMessage {
            VStack(alignment: .leading, spacing: 8) { Label("Needs your attention", systemImage: "exclamationmark.triangle").font(.headline); Text(error).font(.callout).textSelection(.enabled); Button("Dismiss message") { session.error = nil; model.errorMessage = nil } }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private var footer: some View {
        HStack {
            Button("Save & close") { model.showOnboarding = false }.keyboardShortcut(.cancelAction).disabled(blocked).help("Keeps this checkpoint; does not mark setup complete")
            Spacer()
            if step != .welcome { Button("Back") { session.progress.visit(OnboardingStep(rawValue: step.rawValue - 1)!) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(blocked) }
            Button(step == .restore ? "Finish setup" : "Continue") {
                if step == .restore { model.finishOnboarding() }
                else { if step == .brain { session.progress.brainSkipped = !session.brainConfigured }; session.progress.advance() }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!session.canContinue(step, model: model))
        }
    }
    private func assurance(_ title: String, _ description: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) { Image(systemName: symbol).foregroundStyle(.indigo).font(.title3).frame(width: 24).accessibilityHidden(true); VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(description).font(.callout).foregroundStyle(.secondary) } }
    }
    private func jobSummary(_ job: ArchiveJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(job.source.lastPathComponent, systemImage: job.state == .verified ? "checkmark.seal" : "doc").font(.headline)
            Text("\(job.state.rawValue.capitalized) · \(model.format(job.snapshot.identity.size))").font(.callout).foregroundStyle(.secondary)
            if let error = job.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}
