import SwiftUI
import AppKit
import CloudNestCore
import Darwin

private struct BrainConnection: Codable, Sendable { let origin: String; let token: String }
private struct BrainRelationship: Codable, Sendable { let target: String; let type: String }
private struct BrainMemory: Codable, Sendable, Identifiable {
    let id: String, project: String, title: String, body: String, source: String, category: String, visibility: String, revision: String
    let parentRevision: String?
    let version: Int
    let createdAt: String, updatedAt: String
    let expiresAt: String?
    let relationships: [BrainRelationship]
    let confidence: String
    let deleted: Bool
}
private struct BrainProposal: Codable, Sendable, Identifiable {
    let id: String, clientId: String, project: String, title: String, body: String, source: String, category: String, createdAt: String, status: String
}
private struct BrainList: Decodable, Sendable { let memories: [BrainMemory]; let cursor: String? }
private struct BrainSaved: Decodable, Sendable { let memory: BrainMemory }
private struct BrainInbox: Decodable, Sendable { let proposals: [BrainProposal] }
private struct BrainStatus: Decodable, Sendable { let configured: Bool; let canonical: Bool }
private struct BrainHandoff: Decodable, Sendable { let text: String }
private struct BrainOK: Decodable, Sendable { let rejected: Bool? }
private final class BrainNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
private enum BrainFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
private actor BrainTransport {
    private let secrets = KeychainStore()
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60; config.urlCache = nil
        session = URLSession(configuration: config, delegate: BrainNoRedirect(), delegateQueue: nil)
    }
    static func validateOrigin(_ value: String) throws -> URL {
        guard let url = URL(string: value), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)) else {
            throw BrainFailure.message("Enter an HTTPS Brain origin without a path, query, or credential. Loopback HTTP is allowed for local development only.")
        }
        return url
    }
    func configuredOrigin() async throws -> String? {
        guard let data = try await secrets.read("brain-owner-connection") else { return nil }
        return try JSONDecoder().decode(BrainConnection.self, from: data).origin
    }
    func configure(origin: String, token: String) async throws {
        let url = try Self.validateOrigin(origin)
        guard token.count >= 32, token.count <= 256, !token.contains(where: \.isWhitespace) else { throw BrainFailure.message("Use the dedicated Brain owner credential. Do not use a Google token or an AI client credential.") }
        let connection = BrainConnection(origin: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), token: token)
        try await secrets.write("brain-owner-connection", value: JSONEncoder().encode(connection))
    }
    func disconnect() async throws { try await secrets.remove("brain-owner-connection") }
    func call<T: Decodable & Sendable>(_ path: String, method: String = "GET", payload: Data? = nil, as type: T.Type = T.self) async throws -> T {
        guard let stored = try await secrets.read("brain-owner-connection") else { throw BrainFailure.message("Connect your self-hosted Brain first.") }
        // Keep origin and credential paired in one atomic Keychain record.
        let connection = try JSONDecoder().decode(BrainConnection.self, from: stored)
        let origin = try Self.validateOrigin(connection.origin)
        guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: "/api/v1" + path, relativeTo: origin)?.absoluteURL, url.host == origin.host, url.port == origin.port, url.scheme == origin.scheme else { throw BrainFailure.message("Invalid Brain route.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = payload
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if payload != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw BrainFailure.message("Unexpected Brain response.") }
        guard response.statusCode == 200 || response.statusCode == 201 else {
            let detail: String
            switch response.statusCode {
            case 401, 403: detail = "Brain authorization was rejected. Review the owner credential and server permissions."
            case 409: detail = "The memory changed or a write is incomplete. Refresh and review the web console’s Recovery section before retrying."
            case 429: detail = "Brain request limit reached. Wait before retrying."
            case 503: detail = "The canonical Brain is unavailable or not configured. Complete its dedicated server-side Google authorization. Local Storage remains available."
            default: detail = "Brain request did not complete (HTTP \(response.statusCode))."
            }
            throw BrainFailure.message(detail)
        }
        var data = Data(); data.reserveCapacity(16_384)
        for try await byte in bytes {
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            guard data.count < 2_097_152 else { throw BrainFailure.message("Brain response exceeded the memory budget. Use narrower search criteria.") }
            data.append(byte)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor
private final class NativeBrainModel: ObservableObject {
    @Published var origin = ""
    @Published var token = ""
    @Published var query = ""
    @Published var project = ""
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    @Published var message = "Connect your independent Brain service."
    @Published var memories: [BrainMemory] = []
    @Published var proposals: [BrainProposal] = []
    @Published var selected: BrainMemory?
    @Published var title = ""
    @Published var body = ""
    @Published var source = ""
    @Published var category = "knowledge"
    @Published var visibility = "approved"
    @Published var editing = false
    @Published var task = ""
    @Published var objective = ""
    @Published var progress = ""
    @Published var unresolved = ""
    @Published var nextAction = ""
    @Published var handoff = ""
    @Published var tab = "Memories"
    @Published var deleting: BrainMemory?
    private var editingRecord: BrainMemory?
    private let transport = BrainTransport()
    func start() async { do { if let value = try await transport.configuredOrigin() { origin = value; await load() } } catch { self.error = error.localizedDescription } }
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { do { try await operation() } catch is CancellationError { message = "Operation cancelled. Review the service’s recovery queue for incomplete writes." } catch { self.error = error.localizedDescription }; busy = false }
    }
    func connect() { run { try await self.transport.configure(origin: self.origin.trimmingCharacters(in: .whitespacesAndNewlines), token: self.token.trimmingCharacters(in: .whitespacesAndNewlines)); self.token = ""; try await self.refresh() } }
    func importConnection() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Choose connection.private.json from the dedicated Brain setup. Review the origin before saving. Google credentials are never imported here."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw BrainFailure.message("Cannot safely open the selected connection file.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 16_384 else { throw BrainFailure.message("Choose the owner-private connection file created by Brain setup. Public, linked or oversized files are refused.") }
            struct Imported: Decodable { let schemaVersion: Int; let baseURL: String; let ownerToken: String }
            let data = try handle.read(upToCount: 16_385) ?? Data()
            let imported = try JSONDecoder().decode(Imported.self, from: data)
            guard imported.schemaVersion == 1 else { throw BrainFailure.message("Unsupported Brain connection file version.") }
            _ = try BrainTransport.validateOrigin(imported.baseURL)
            guard imported.ownerToken.count >= 32, imported.ownerToken.count <= 256, !imported.ownerToken.contains(where: \.isWhitespace) else { throw BrainFailure.message("Invalid owner credential format.") }
            origin = imported.baseURL; token = imported.ownerToken; message = "Connection loaded for review. Save in Keychain & connect when the displayed Brain origin is correct."
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() { run { try await self.transport.disconnect(); self.connected = false; self.memories = []; self.proposals = []; self.selected = nil; self.handoff = ""; self.token = ""; self.title = ""; self.body = ""; self.source = ""; self.query = ""; self.project = ""; self.task = ""; self.objective = ""; self.progress = ""; self.unresolved = ""; self.nextAction = ""; self.editing = false; self.editingRecord = nil; self.deleting = nil; self.message = "Brain disconnected locally. Use the server’s credential controls to revoke access." } }
    func load() async { guard !busy else { return }; busy = true; defer { busy = false }; do { try await refresh() } catch { self.error = error.localizedDescription } }
    private func refresh() async throws {
        let status: BrainStatus = try await transport.call("/status")
        guard status.configured, status.canonical else { throw BrainFailure.message("A canonical Drive-backed Brain is required before storing personal memories.") }
        connected = true
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "project", value: project), URLQueryItem(name: "limit", value: "20")]
        let list: BrainList = try await transport.call("/memories?" + (components.percentEncodedQuery ?? "")); memories = list.memories
        let inbox: BrainInbox = try await transport.call("/inbox"); proposals = inbox.proposals
        message = "\(memories.count) memories · \(proposals.count) proposals. Showing up to 20 matches; narrow the search or open the Console for paginated results."
    }
    func newMemory() { editingRecord = nil; title = ""; body = ""; source = ""; category = "knowledge"; visibility = "approved"; editing = true }
    func edit(_ record: BrainMemory) { editingRecord = record; title = record.title; body = record.body; source = record.source; project = record.project; category = record.category; visibility = record.visibility; editing = true }
    func save() { run {
        guard !self.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !self.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !self.project.isEmpty, !self.source.isEmpty else { throw BrainFailure.message("Add a title, project, memory and source before saving.") }
        var payload: [String: String] = ["title": self.title, "project": self.project, "body": self.body, "source": self.source, "category": self.category, "visibility": self.visibility]
        if let record = self.editingRecord { payload["expectedRevision"] = record.revision } else { payload["confidence"] = "user-confirmed" }
        let saved: BrainSaved = try await self.transport.call(self.editingRecord.map { "/memories/" + $0.id } ?? "/memories", method: self.editingRecord == nil ? "POST" : "PATCH", payload: JSONSerialization.data(withJSONObject: payload))
        self.editing = false; self.selected = saved.memory; try await self.refresh()
    } }
    func delete(_ record: BrainMemory) { run {
        let _: BrainSaved = try await self.transport.call("/memories/" + record.id, method: "DELETE", payload: JSONSerialization.data(withJSONObject: ["expectedRevision": record.revision])); self.selected = nil; try await self.refresh()
    } }
    func review(_ proposal: BrainProposal, approve: Bool, privateMemory: Bool = false) { run {
        if approve { let _: BrainSaved = try await self.transport.call("/inbox/" + proposal.id + "/approve", method: "POST", payload: JSONSerialization.data(withJSONObject: ["visibility": privateMemory ? "private" : "approved"])) }
        else { let _: BrainOK = try await self.transport.call("/inbox/" + proposal.id + "/reject", method: "POST", payload: Data("{}".utf8)) }
        try await self.refresh()
    } }
    func generateHandoff() { run {
        let payload = ["project": self.project, "task": self.task, "objective": self.objective, "progress": self.progress, "unresolved": self.unresolved, "nextAction": self.nextAction]
        let result: BrainHandoff = try await self.transport.call("/handoff", method: "POST", payload: JSONSerialization.data(withJSONObject: payload)); self.handoff = result.text; self.message = "Review the editable handoff, then copy it into your next assistant. Nothing was sent automatically."
    } }
    func openConsole() { do { let url = try BrainTransport.validateOrigin(origin); NSWorkspace.shared.open(url) } catch { self.error = error.localizedDescription } }
    func copyHandoff() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(handoff, forType: .string); message = "Handoff copied. Paste it into your chosen assistant." }
}

struct NativeBrainView: View {
    @StateObject private var model = NativeBrainModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 7) { Text("A memory that travels with you.").font(.largeTitle.bold()); Text("Portable knowledge, explicit permissions, and no required model API.").foregroundStyle(.secondary) }; Spacer(); if model.busy { ProgressView().controlSize(.small) } }
            if !model.connected {
                GroupBox("Connect your independent Brain") {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("The Brain runs in your cloud account, so approved memories stay available when this Mac is off. It requires its own authorized Drive connection.").foregroundStyle(.secondary)
                        TextField("HTTPS Brain origin", text: $model.origin).textFieldStyle(.roundedBorder)
                        SecureField("Dedicated Brain owner credential", text: $model.token).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Import setup connection…", action: model.importConnection).disabled(model.busy)
                            Button("Save in Keychain & connect", action: model.connect).buttonStyle(.borderedProminent).disabled(model.busy || model.origin.isEmpty || model.token.isEmpty)
                            Button("Forget saved connection", action: model.disconnect).disabled(model.busy)
                        }
                        Text("Owner credentials manage your vault. Give AI assistants separate scoped client credentials; never share this owner credential with them.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
            } else {
                HStack { Label("Canonical mode authorized", systemImage: "checkmark.shield").foregroundStyle(.green); Spacer(); Button("Open Brain Console", action: model.openConsole); Button("Refresh") { Task { await model.load() } }.disabled(model.busy); Button("Disconnect", action: model.disconnect).disabled(model.busy) }
                Picker("Brain workspace", selection: $model.tab) { Text("Memories").tag("Memories"); Text("Inbox (\(model.proposals.count))").tag("Inbox"); Text("Continue in Another AI").tag("Handoff") }.pickerStyle(.segmented)
                if model.tab == "Memories" { memories }
                else if model.tab == "Inbox" { inbox }
                else { handoff }
            }
            Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(4)
        .task { await model.start() }
        .sheet(isPresented: $model.editing) { editor }
        .alert("Brain", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete this memory? A canonical tombstone hides it from AI search; revision history remains recoverable in the Brain Console.", isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } }), titleVisibility: .visible) { Button("Delete memory", role: .destructive) { if let record = model.deleting { model.delete(record) }; model.deleting = nil }; Button("Cancel", role: .cancel) { model.deleting = nil } }
    }
    private var memories: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { TextField("Search memories", text: $model.query); TextField("Project filter", text: $model.project).frame(maxWidth: 180); Button("Search") { Task { await model.load() } }; Button("New memory", action: model.newMemory).buttonStyle(.borderedProminent) }.disabled(model.busy)
            if model.memories.isEmpty { ContentUnavailableView("No matching memories", systemImage: "brain", description: Text("Create a user-confirmed note or review an AI proposal.")) }
            else { HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) { ForEach(model.memories) { record in Button { model.selected = record } label: { VStack(alignment: .leading, spacing: 5) { Text(record.title).font(.headline); Text("\(record.project) · \(record.visibility)").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(model.selected?.id == record.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain) } }.frame(maxWidth: 300)
                if let record = model.selected { VStack(alignment: .leading, spacing: 16) { Text(record.title).font(.title2.bold()); Text(record.body).textSelection(.enabled); Text("Source: \(record.source)\nRevision \(record.version) · \(record.confidence)\n\(record.updatedAt)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled); HStack { Button("Edit") { model.edit(record) }; Button("History in Console", action: model.openConsole); Button("Delete…", role: .destructive) { model.deleting = record } }.disabled(model.busy) }.frame(maxWidth: .infinity, alignment: .leading) }
                else { Text("Select a memory to inspect its source and revision.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            } }
        }
    }
    private var inbox: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Suggestions remain unapproved until you act. You can edit approved memories afterward; no AI client can silently overwrite them.").foregroundStyle(.secondary)
            if model.proposals.isEmpty { ContentUnavailableView("Inbox clear", systemImage: "tray", description: Text("Only clients explicitly granted proposal access can submit suggestions.")) }
            ForEach(model.proposals) { proposal in GroupBox { VStack(alignment: .leading, spacing: 12) { Text(proposal.title).font(.headline); Text(proposal.body).textSelection(.enabled); Text("\(proposal.project) · Proposed by \(proposal.clientId)\nSource: \(proposal.source)").font(.caption).foregroundStyle(.secondary); HStack { Button("Approve") { model.review(proposal, approve: true) }; Button("Keep private") { model.review(proposal, approve: true, privateMemory: true) }; Button("Reject") { model.review(proposal, approve: false) } }.disabled(model.busy) }.padding(10) } }
        }
    }
    private var handoff: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create an editable handoff for Claude, ChatGPT, Gemini, DeepSeek, Kimi, or a coding assistant. Copy it manually; automatic chat synchronization is not claimed.").foregroundStyle(.secondary)
            HStack { TextField("Project", text: $model.project); TextField("Current task", text: $model.task) }
            TextField("Objective", text: $model.objective); TextField("Progress", text: $model.progress); TextField("Unresolved issues", text: $model.unresolved); TextField("Next action", text: $model.nextAction)
            Button("Generate handoff", action: model.generateHandoff).buttonStyle(.borderedProminent).disabled(model.busy || model.project.isEmpty || model.task.isEmpty)
            TextEditor(text: $model.handoff).font(.system(.body, design: .monospaced)).frame(minHeight: 230).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
            Button("Copy handoff", action: model.copyHandoff).disabled(model.handoff.isEmpty)
        }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save a verified source, not an assumption.").font(.title2.bold())
            TextField("Title", text: $model.title); TextField("Project", text: $model.project); TextField("Category", text: $model.category)
            TextEditor(text: $model.body).frame(minHeight: 200).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.2)))
            TextField("Source / provenance", text: $model.source)
            Picker("Visibility", selection: $model.visibility) { Text("Approved for scoped AI clients").tag("approved"); Text("Private — owner only").tag("private") }
            HStack { Button("Cancel") { model.editing = false }; Spacer(); Button("Save revision", action: model.save).buttonStyle(.borderedProminent).disabled(model.busy) }
        }.padding(26).frame(width: 620).disabled(model.busy)
    }
}
