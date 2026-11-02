import SwiftUI
import CloudNestCore

struct ProductPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.07)))
    }
}
struct FreeSpaceView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Room for what comes next.").font(.largeTitle.bold())
                Text("Review ranked candidates from folders you approved. Size and modification age guide the order; they do not prove a file is inactive.").foregroundStyle(.secondary)
            }
            ProductPanel {
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected allocation estimate").font(.caption).foregroundStyle(.secondary)
                        Text(model.format(model.recommendedAllocation)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        Text("APFS clones and snapshots affect actual savings.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("Historical observed free-space increase").font(.caption).foregroundStyle(.secondary)
                        Text(model.format(model.observedFreeIncrease)).font(.title2.bold()).monospacedDigit()
                        Text("Measured only during approved managed removal.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Analyze approved folders", action: { model.scanApprovedFolders() }).disabled(model.busy)
                    Text("\(model.approvedFolders.count) approved folders").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Archive \(model.selectedRecommendations.count) selected", action: model.archiveSelectedRecommendations)
                        .buttonStyle(.borderedProminent).disabled(model.busy || !model.connected || model.selectedRecommendations.isEmpty)
                }
                Text("Archiving retains all originals. Cleanup is a separate, explicitly approved action after cloud verification.").font(.caption).foregroundStyle(.secondary)
            }
            if model.recommendations.isEmpty {
                ContentUnavailableView("No recommendations yet", systemImage: "leaf", description: Text("Choose approved folders and analyze them, or adjust the rules in Storage. No file is changed by analysis."))
            } else {
                ProductPanel {
                    HStack { Text("Review candidates").font(.headline); Spacer(); Button("Include all") { model.excludedRecommendationIDs = [] }.disabled(model.busy) }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.recommendations.prefix(200)) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Button { model.excludeRecommendation(item.id) } label: {
                                    Image(systemName: model.excludedRecommendationIDs.contains(item.id) ? "circle" : "checkmark.circle.fill").font(.title3)
                                }.buttonStyle(.plain).accessibilityLabel(model.excludedRecommendationIDs.contains(item.id) ? "Include \(item.candidate.url.lastPathComponent)" : "Exclude \(item.candidate.url.lastPathComponent)").disabled(model.busy)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.candidate.url.lastPathComponent).font(.headline)
                                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                    Text(item.candidate.url.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                }.opacity(model.excludedRecommendationIDs.contains(item.id) ? 0.5 : 1)
                                Spacer(); Text(model.format(item.candidate.logicalBytes)).monospacedDigit().foregroundStyle(.secondary)
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }
                    if model.recommendations.count > 200 { Text("Showing the first 200 ranked candidates. Narrow the approved folders or rules for a smaller review set; Only displayed candidates can be selected for this batch.").font(.caption).foregroundStyle(.secondary) }
                }
                ProductPanel {
                    Text("Eligible allocation by category").font(.headline)
                    ForEach(SpaceRescue.byCategory(model.report)) { group in
                        HStack { Text(group.id); Spacer(); Text("\(group.files) files · \(model.format(group.allocatedBytes))").monospacedDigit().foregroundStyle(.secondary) }
                        ProgressView(value: Double(group.allocatedBytes), total: Double(max(1, model.report.allocatedBytes))).tint(.indigo)
                    }
                    Text("This breakdown covers eligible scan matches, not the entire SSD.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
struct ActivityView: View {
    @ObservedObject var model: AppModel
    private func symbol(_ kind: StorageActivity.Kind) -> String {
        switch kind {
        case .archiveVerified, .folderVerified: "checkmark.seal"
        case .restored, .putBack: "arrow.uturn.backward"
        case .recoveryStaged: "tray.and.arrow.down"
        case .removed: "leaf"
        case .scanned: "magnifyingglass"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) { Text("A clear record.").font(.largeTitle.bold()); Text("Actions observed by this version of CloudNest. Older jobs remain in Archive Library; their completion times are not invented here.").foregroundStyle(.secondary) }
            if model.busy {
                ProductPanel {
                    HStack { ProgressView().controlSize(.small); Text(model.message); Spacer(); if model.canCancel { Button("Pause", action: model.cancelOperation) } }
                }
            }
            if model.activities.isEmpty { ContentUnavailableView("No recorded activity yet", systemImage: "clock", description: Text("Completed scans, verified uploads, restores and recovery actions will appear here.")) }
            else {
                ProductPanel {
                    ForEach(model.activities) { event in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: symbol(event.kind)).foregroundStyle(.indigo).font(.title3).frame(width: 26)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.title).font(.headline)
                                Text(event.kind.rawValue.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).capitalized).font(.caption).foregroundStyle(.secondary)
                                if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                if event.bytes > 0 { Text("\(model.format(event.bytes)) of file content").font(.caption).foregroundStyle(.secondary) }
                                if event.kind == .removed { Text("Observed free-space increase: \(model.format(event.observedFreeBytes))").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(); Text(event.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    HStack {
                        Text("\(model.activityCount) recorded events").font(.caption).foregroundStyle(.secondary); Spacer()
                        Button("Previous") { model.activityPage(-1) }.disabled(model.activityOffset == 0)
                        Button("Next") { model.activityPage(1) }.disabled(model.activityOffset + model.activities.count >= model.activityCount)
                    }
                }
            }
        }.task { await model.refreshActivities() }
    }
}
struct RecoveryCenterView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) { Text("Nothing disappears quietly.").font(.largeTitle.bold()); Text("Managed recovery copies remain local until you separately approve permanent removal. Put back works without a cloud connection.").foregroundStyle(.secondary) }
            Button("Open Smart Sweep recovery") { model.selection = "Smart Sweep" }.disabled(model.busy)
            ProductPanel {
                HStack { Label("Local bytes retained in recovery", systemImage: "tray.and.arrow.down").font(.headline); Spacer(); Text(model.format(model.recoveryBytes)).font(.title2.bold()).monospacedDigit() }
                HStack { Button("Refresh recovery") { Task { await model.refreshRecovery() } }.disabled(model.busy); Button("Restore from manifest…", action: model.restoreFromManifest).disabled(model.busy || !model.connected) }
                Text("Cloud restore verifies content before installation. Existing files are never overwritten.").font(.caption).foregroundStyle(.secondary)
            }
            if model.recoveryFiles.isEmpty && model.folderRecoveryRecords.isEmpty { ContentUnavailableView("No managed recovery files", systemImage: "checkmark.shield", description: Text("Reclaim from Archive Library first verifies an archive and retains its original locally. It does not immediately free space.")) }
            if !model.recoveryFiles.isEmpty {
                ProductPanel {
                    ForEach(model.recoveryFiles) { job in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.source.lastPathComponent).font(.headline)
                                Text("\(job.recovery?.stage.rawValue ?? "unknown") · \(model.format(job.recovery?.retainedBytes ?? 0)) retained").font(.caption).foregroundStyle(.secondary)
                                Text(job.source.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                if let error = job.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            if job.recovery?.stage == .retained || job.recovery?.stage == .needsReview {
                                Button("Put back") { model.recoverOriginal(job) }.disabled(model.busy)
                                if job.recovery?.stage == .retained { Button("Remove copy…", role: .destructive) { model.removeRecovery(job) }.disabled(model.busy || !model.connected) }
                            }
                            Button("Restore cloud copy…") { model.restore(job) }.disabled(model.busy || !model.connected)
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    HStack { Text("\(model.recoveryFileCount) retained file jobs").font(.caption); Spacer(); Button("Previous files") { model.recoveryFilePage(-1) }.disabled(model.busy || model.recoveryFileOffset == 0); Button("Next files") { model.recoveryFilePage(1) }.disabled(model.busy || model.recoveryFileOffset + model.recoveryFiles.count >= model.recoveryFileCount) }
                }
            }
            if !model.folderRecoveryRecords.isEmpty {
                ProductPanel {
                    Text("Managed folder groups").font(.headline)
                    ForEach(model.folderRecoveryRecords) { record in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { VStack(alignment: .leading, spacing: 5) { Text(record.source.lastPathComponent).font(.headline); Text("\(record.stage.rawValue) · \(model.format(record.retainedBytes)) retained").font(.caption).foregroundStyle(.secondary); Text(record.source.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }; Spacer() }
                            HStack {
                                if record.canPutBack { Button("Put back folder") { model.putBackFolder(record.id, name: record.source.lastPathComponent) }.disabled(model.busy) }
                                if record.stage == .retained || record.stage == .removing { Button("Remove managed folder…", role: .destructive) { model.removeFolderRecovery(record.id, name: record.source.lastPathComponent, bytes: record.retainedBytes) }.disabled(model.busy || !model.connected) }
                                Button("Inspect retained folder") { model.revealFolderRecovery(record) }.disabled(model.busy)
                                Button("Restore cloud folder…") { model.restoreManagedFolder(record.id) }.disabled(model.busy || !model.connected)
                            }
                            if !record.canPutBack && record.stage != .moving && record.stage != .puttingBack { Text("A partial cleanup cannot be put back as a complete folder. Restore the cloud archive into a new destination, or approve cleanup continuation after review.").font(.caption).foregroundStyle(.orange) }
                        }.padding(.vertical, 8); Divider()
                    }
                    HStack { Text("\(model.folderRecoveryCount) retained folder groups").font(.caption); Spacer(); Button("Previous folders") { model.folderRecoveryPage(-1) }.disabled(model.busy || model.folderRecoveryOffset == 0); Button("Next folders") { model.folderRecoveryPage(1) }.disabled(model.busy || model.folderRecoveryOffset + model.folderRecoveryRecords.count >= model.folderRecoveryCount) }
                }
            }
            ProductPanel {
                Label("Remote restore requests", systemImage: "arrow.down.circle").font(.headline)
                Text("Requests from your authenticated Brain wait for local review. The Mac chooses and validates every destination. Reading this queue never starts a restore.").font(.caption).foregroundStyle(.secondary)
                Button("Check remote restore queue", action: model.refreshRemoteRestoreRequests).disabled(model.busy)
                ForEach(model.remoteRestoreRequests) { request in
                    HStack { VStack(alignment: .leading, spacing: 5) { Text(request.archiveName ?? request.archiveId.uuidString).font(.headline); Text(request.createdAt).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Review & restore…") { model.reviewRemoteRestore(request) }.disabled(model.busy || !model.connected); Button("Dismiss request") { model.dismissRemoteRestore(request) }.disabled(model.busy) }; Divider()
                }
            }
        }.task { await model.refreshRecovery() }
    }
}
struct ProductSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ProductPanel {
                Label("Transfer policies", systemImage: "network").font(.headline)
                Toggle("Apply network, power and upload pacing rules", isOn: $model.transferPolicy.enabled)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Require external power", isOn: $model.transferPolicy.requireExternalPower)
                    Toggle("Pause in Low Power Mode", isOn: $model.transferPolicy.pauseInLowPowerMode)
                    Toggle("Allow networks marked expensive", isOn: $model.transferPolicy.allowExpensiveNetworks)
                    Toggle("Allow Low Data Mode networks", isOn: $model.transferPolicy.allowConstrainedNetworks)
                    Picker("Average upload limit", selection: $model.transferPolicy.uploadBytesPerSecond) {
                        Text("Unlimited").tag(Int64(0)); Text("256 KB/s").tag(Int64(256_000)); Text("1 MB/s").tag(Int64(1_000_000)); Text("5 MB/s").tag(Int64(5_000_000)); Text("10 MB/s").tag(Int64(10_000_000))
                    }.frame(maxWidth: 360)
                    Stepper("Transient retries: \(model.transferPolicy.maximumRetries)", value: $model.transferPolicy.maximumRetries, in: 0...5)
                }.disabled(!model.transferPolicy.enabled)
                Text("Rules are checked before requests and upload chunks. A rule violation pauses the operation; use Resume after conditions change. Upload pacing limits the average rate, with bounded chunk bursts. Downloads are checked before they start. Non-idempotent writes are never blindly retried.").font(.caption).foregroundStyle(.secondary)
            }
            ProductPanel {
                Label("Recommendation rules", systemImage: "slider.horizontal.3").font(.headline)
                TextField("Exclude extensions, comma separated", text: Binding(get: { model.recommendationRules.excludedExtensions.joined(separator: ", ") }, set: { model.recommendationRules.excludedExtensions = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }))
                TextField("Exclude folder names, comma separated", text: Binding(get: { model.recommendationRules.excludedPathComponents.joined(separator: ", ") }, set: { model.recommendationRules.excludedPathComponents = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }))
                Text("Custom exclusions apply to recommendation scans. Protected folders and built-in security exclusions independently block file operations.").font(.caption).foregroundStyle(.secondary)
                Toggle("Schedule recommendation scans while CloudNest is open", isOn: $model.recommendationSchedule.enabled).disabled(model.approvedFolders.isEmpty)
                Picker("Schedule", selection: $model.recommendationSchedule.frequency) {
                    Text("Daily").tag(RecommendationSchedule.Frequency.daily); Text("Weekly").tag(RecommendationSchedule.Frequency.weekly); Text("Every 30 days").tag(RecommendationSchedule.Frequency.monthly)
                }.disabled(!model.recommendationSchedule.enabled).frame(maxWidth: 300)
                Text("Only explicitly approved folders are scanned. Optional login startup is controlled separately; overdue work is checked when the app next opens. Scheduling never grants upload or deletion permission.").font(.caption).foregroundStyle(.secondary)
            }
            ProductPanel {
                Label("Open at login", systemImage: "power").font(.headline)
                Text(model.loginStatus).foregroundStyle(.secondary)
                HStack { Button(model.loginEnabled ? "Disable login startup" : "Enable login startup") { model.setLoginItem(!model.loginEnabled) }.disabled(model.busy || !model.loginEnabled && !model.canRegisterLoginItem); Button("macOS Login Items", action: model.openLoginSettings) }
                Text("Opt-in startup uses the existing native app as the login item. No second resident helper or renderer is added. Scheduled recommendations run only while CloudNest is open, and never authorize uploads or cleanup.").font(.caption).foregroundStyle(.secondary)
                if !model.canRegisterLoginItem { Text("Install this app in Applications before enabling startup.").font(.caption).foregroundStyle(.secondary) }
            }.task { model.refreshLoginStatus() }
            ProductPanel {
                Label("Storage Guardian", systemImage: "bell.badge").font(.headline)
                Text(model.notificationStatus).font(.callout).foregroundStyle(.secondary)
                if model.lowDiskNotificationsEnabled { Button("Disable low-storage notifications", action: model.disableLowDiskNotifications) }
                else { Button("Enable low-storage notifications…", action: model.enableLowDiskNotifications) }
                Text("Requests macOS permission only when enabled. Notifications contain no file names or paths and do not trigger deletion.").font(.caption).foregroundStyle(.secondary)
            }
            ProductPanel {
                Label("Approved scan folders", systemImage: "folder.badge.checkmark").font(.headline)
                ForEach(model.approvedFolders, id: \.path) { folder in
                    HStack { Text(folder.path).font(.caption).textSelection(.enabled); Spacer(); Button("Forget") { model.forgetApprovedFolder(folder) } }
                }
                Button("Choose approved folder…", action: model.addApprovedFolder)
                Button("Open setup guide") { model.showOnboarding = true }
            }
        }.disabled(model.busy)
    }
}
@MainActor private final class CommandSearch: ObservableObject { @Published var query = "" }

struct WelcomeSetupView: View {
    @ObservedObject var model: AppModel
    var body: some View { OnboardingView(model: model) }
}
struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @StateObject private var search = CommandSearch()
    private var commands: [String] { ["Overview", "Storage", "Free Up Space", "Smart Sweep", "Model Parking", "Hibernate Project", "Archive Library", "Activity", "Recovery Center", "Settings & Security", "Scan a folder…", "Archive a folder…", "Restore from manifest…", "Setup guide"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Find a command", text: $search.query).textFieldStyle(.roundedBorder).accessibilityLabel("Search commands")
            ForEach(commands.filter { search.query.isEmpty || $0.localizedCaseInsensitiveContains(search.query) }, id: \.self) { command in
                Button(command) { model.showCommands = false; model.performCommand(command) }.buttonStyle(.plain).padding(.vertical, 5)
            }
            HStack { Spacer(); Button("Close") { model.showCommands = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 440)
    }
}
