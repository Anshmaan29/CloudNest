import Testing
import Foundation
import Network
import Darwin
@testable import CloudNestCore

private actor OAuthFixtureSecrets: SecretStore {
    var values: [String: Data]
    var mutations = 0
    init(client: Data, tokens: Data?) { values = ["google-client": client]; values["google-tokens"] = tokens }
    func read(_ key: String) -> Data? { values[key] }
    func write(_ key: String, value: Data) { mutations += 1; values[key] = value }
    func remove(_ key: String) { mutations += 1; values.removeValue(forKey: key) }
}
private struct OAuthHTTPReply: Sendable {
    var status = 200
    var body: Data
    static func tokens(_ access: String, refresh: String? = nil, scope: String? = GoogleOAuth.scope) throws -> Self {
        var object: [String: Any] = ["access_token": access, "expires_in": 3600, "token_type": "Bearer"]
        object["refresh_token"] = refresh; object["scope"] = scope
        return Self(body: try JSONSerialization.data(withJSONObject: object))
    }
}
private final class OAuthHTTPProfile: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var handler: @Sendable (URLRequest) async throws -> OAuthHTTPReply
    init(_ handler: @escaping @Sendable (URLRequest) async throws -> OAuthHTTPReply) { self.handler = handler }
    func set(_ value: @escaping @Sendable (URLRequest) async throws -> OAuthHTTPReply) { lock.lock(); handler = value; lock.unlock() }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func route(_ request: URLRequest) -> @Sendable (URLRequest) async throws -> OAuthHTTPReply { lock.lock(); defer { lock.unlock() }; requests.append(request); return handler }
}
private final class OAuthHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock(); private var profiles: [String: OAuthHTTPProfile] = [:]
    func add(_ key: String, _ value: OAuthHTTPProfile) { lock.lock(); profiles[key] = value; lock.unlock() }
    func get(_ key: String) -> OAuthHTTPProfile? { lock.lock(); defer { lock.unlock() }; return profiles[key] }
}
private final class OAuthHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = OAuthHTTPRegistry()
    private var work: Task<Void, Never>?
    static func fields(_ request: URLRequest) -> [String: String] {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while body.count < 65536 { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        let items = URLComponents(string: "https://example.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
    override class func canInit(with request: URLRequest) -> Bool { true } // Tests never fall through to a live network.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fields = Self.fields(request)
        guard let profile = Self.registry.get(fields["client_id"] ?? fields["token"] ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        var recorded = request; recorded.httpBody = GoogleOAuth.form(fields)
        let handler = profile.route(recorded)
        work = Task.detached(priority: .utility) { @Sendable [self, recorded, handler] in
            do {
                let reply = try await handler(recorded); try Task.checkCancellation()
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { throw NestError.invalidResponse }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for offset in stride(from: 0, to: reply.body.count, by: 4096) { client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<min(offset + 4096, reply.body.count))) }
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { work?.cancel() }
}
private struct OAuthFixture: Sendable {
    let base: URL
    let clientID: String
    let clientData: Data
    let access = "fixture-access-" + UUID().uuidString
    let refresh = "fixture-refresh-" + UUID().uuidString
    let secrets: OAuthFixtureSecrets
    let profile: OAuthHTTPProfile
    init(legacy: Bool = true) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        base = repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/oauth-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        clientID = String(repeating: "2", count: 12) + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".apps.googleusercontent.com"
        clientData = try JSONEncoder().encode(OAuthClient(client_id: clientID, client_secret: String(repeating: "s", count: 32)))
        let tokens = legacy ? try Self.credential(access: "legacy-cached-" + UUID().uuidString, refresh: refresh) : nil
        secrets = OAuthFixtureSecrets(client: clientData, tokens: tokens)
        let reply = try OAuthHTTPReply.tokens(access)
        profile = OAuthHTTPProfile { _ in reply }
        OAuthHTTPProtocol.registry.add(clientID, profile); OAuthHTTPProtocol.registry.add(refresh, profile); OAuthHTTPProtocol.registry.add(access, profile)
    }
    static func credential(access: String, refresh: String?, clientID: String? = nil) throws -> Data {
        struct Value: Encodable { let accessToken: String; let refreshToken: String?; let expiresAt: Date; let clientID: String? }
        return try JSONEncoder().encode(Value(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600), clientID: clientID))
    }
    func oauth(authorization: (@Sendable (URL) async throws -> String)? = nil) -> GoogleOAuth {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthHTTPProtocol.self]
        return GoogleOAuth(secrets: secrets, configuration: config, authorization: authorization)
    }
    func document(_ client: OAuthClient? = nil, name: String = "client.json") throws -> URL {
        let object = try JSONSerialization.jsonObject(with: client.map { try JSONEncoder().encode($0) } ?? clientData)
        let url = base.appendingPathComponent(name); try JSONSerialization.data(withJSONObject: ["installed": object]).write(to: url); return url
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
}
private final class GoogleLocalHTTP: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "cloudnest.test.google-http")
    private let lock = NSLock(); private var hits = 0; private var connections: [NWConnection] = []
    let response: Data?
    var port: UInt16 { listener.port!.rawValue }
    var count: Int { lock.lock(); defer { lock.unlock() }; return hits }
    init(response: Data?) throws {
        self.response = response
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters); let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock(); connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] _, _, _, _ in
                guard let self else { return }; self.lock.lock(); self.hits += 1; self.lock.unlock()
                if let response = self.response { connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
            }
        }
        listener.start(queue: queue); guard ready.wait(timeout: .now() + 3) == .success else { throw NestError.invalidResponse }
    }
    func stop() { listener.cancel(); lock.lock(); let current = connections; connections = []; lock.unlock(); current.forEach { $0.cancel() } }
}

@Test func googleClientImportRejectsInvalidHugeLinkedAndNonRegularInputsBeforeChangingGrant() async throws {
    let f = try OAuthFixture(); defer { f.clean() }; let oauth = f.oauth()
    let initial = await f.secrets.values, invalid = f.base.appendingPathComponent("bad.json")
    let valid = try f.document()
    let malformed = [Data("not json".utf8), Data(repeating: 32, count: 131073), try JSONSerialization.data(withJSONObject: ["web": ["client_id": f.clientID]])]
    for data in malformed { try data.write(to: invalid); await #expect(throws: (any Error).self) { try await oauth.importClient(from: invalid) } }
    for client in [OAuthClient(client_id: "https://example.invalid/apps.googleusercontent.com", client_secret: nil), OAuthClient(client_id: "notgoogle.apps.googleusercontent.com", client_secret: nil), OAuthClient(client_id: f.clientID, client_secret: ""), OAuthClient(client_id: f.clientID, client_secret: String(repeating: "s", count: 513)), OAuthClient(client_id: f.clientID, client_secret: "has whitespace")] {
        let input = try f.document(client, name: "invalid-client.json"); await #expect(throws: (any Error).self) { try await oauth.importClient(from: input) }
    }
    let link = f.base.appendingPathComponent("link.json"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
    await #expect(throws: (any Error).self) { try await oauth.importClient(from: link) }
    let hard = f.base.appendingPathComponent("hard.json"); try FileManager.default.linkItem(at: valid, to: hard)
    await #expect(throws: (any Error).self) { try await oauth.importClient(from: hard) }
    let fifo = f.base.appendingPathComponent("fifo.json"); #expect(mkfifo(fifo.path, 0o600) == 0)
    await #expect(throws: (any Error).self) { try await oauth.importClient(from: fifo) }
    #expect(await f.secrets.values == initial)
    #expect(await f.secrets.mutations == 0)
    try FileManager.default.removeItem(at: hard)
    try await oauth.importClient(from: valid)
    #expect(await f.secrets.values["google-tokens"] == nil)
    let saved = try #require(await f.secrets.values["google-client"]), client = try JSONDecoder().decode(OAuthClient.self, from: saved)
    #expect(client.client_id == f.clientID && client.client_secret == String(repeating: "s", count: 32))
}

@Test func googleLegacyCredentialRefreshesBeforeBindingAndCachedReuse() async throws {
    let f = try OAuthFixture(); defer { f.clean() }; let oauth = f.oauth()
    #expect(try await oauth.accessToken() == f.access)
    #expect(try await oauth.accessToken() == f.access)
    #expect(f.profile.snapshot().count == 1)
    let stored = try #require(await f.secrets.values["google-tokens"]), value = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(value["clientID"] as? String == f.clientID && (value["clientFingerprint"] as? String)?.count == 64)
    #expect(value["refreshToken"] as? String == f.refresh)
    let request = try #require(f.profile.snapshot().first), fields = OAuthHTTPProtocol.fields(request)
    #expect(fields["client_id"] == f.clientID && fields["grant_type"] == "refresh_token")
    #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token" && request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func googleWrongBoundClientAndLegacyWithoutRefreshNeverReuseCachedAccessToken() async throws {
    let f = try OAuthFixture(); defer { f.clean() }
    let wrong = try OAuthFixture.credential(access: f.access, refresh: f.refresh, clientID: "different-client")
    await f.secrets.write("google-tokens", value: wrong)
    await #expect(throws: (any Error).self) { try await f.oauth().accessToken() }
    #expect(f.profile.snapshot().isEmpty)
    try await f.secrets.write("google-tokens", value: OAuthFixture.credential(access: f.access, refresh: nil))
    await #expect(throws: (any Error).self) { try await f.oauth().accessToken() }
    #expect(f.profile.snapshot().isEmpty)
}

@Test func googleConcurrentRefreshesCoalesceWithoutOverwritingNewerCredential() async throws {
    let f = try OAuthFixture(); defer { f.clean() }; let oauth = f.oauth()
    let reply = try OAuthHTTPReply.tokens(f.access)
    f.profile.set { _ in try await Task.sleep(for: .milliseconds(30)); return reply }
    async let first = oauth.accessToken(); async let second = oauth.accessToken()
    let tokens = try await [first,second]; #expect(tokens == [f.access,f.access]); #expect(f.profile.snapshot().count == 1)
}

@Test func googleLateRefreshCannotOverwriteAnotherActorsNewClientGrant() async throws {
    let f = try OAuthFixture(), other = try OAuthFixture(legacy: false); defer { f.clean(); other.clean() }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthHTTPProtocol.self]
    let second = GoogleOAuth(secrets: f.secrets, configuration: config, authorization: { _ in "fixture-code" })
    let newClient = try JSONDecoder().decode(OAuthClient.self, from: other.clientData), path = try f.document(newClient, name: "replacement.json")
    let newer = try OAuthHTTPReply.tokens(other.access, refresh: other.refresh), older = try OAuthHTTPReply.tokens(f.access)
    other.profile.set { _ in newer }
    f.profile.set { _ in try await second.importClient(from: path); try await second.signIn(); return older }
    await #expect(throws: (any Error).self) { try await f.oauth().accessToken() }
    #expect(try await second.accessToken() == other.access)
    let stored = try #require(await f.secrets.values["google-tokens"]), value = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(value["clientID"] as? String == other.clientID && value["accessToken"] as? String == other.access)
}

@Test func googleSignInRefusesSameClientReimportDuringBrowserConsentWithoutClearingNewGrant() async throws {
    let f = try OAuthFixture(legacy: false); defer { f.clean() }; let file = try f.document()
    let second = f.oauth(authorization: { _ in "new-fixture-code" }), reply = try OAuthHTTPReply.tokens(f.access, refresh: f.refresh)
    f.profile.set { _ in reply }
    let first = f.oauth(authorization: { url in
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value == GoogleOAuth.scope)
        try await second.importClient(from: file); try await second.signIn(); return "old-fixture-code"
    })
    await #expect(throws: (any Error).self) { try await first.signIn() }
    #expect(try await second.accessToken() == f.access && f.profile.snapshot().count == 1)
}

@Test func googleOversizeAndInvalidTokenResponsesLeaveExistingGrantUntouched() async throws {
    let f = try OAuthFixture(); defer { f.clean() }; let original = await f.secrets.values["google-tokens"]
    for reply in [OAuthHTTPReply(body: Data(repeating: 32, count: 65537)), OAuthHTTPReply(body: Data("{\"access_token\":\"bad token with spaces\",\"expires_in\":3600}".utf8)), OAuthHTTPReply(status: 400, body: Data("{\"error\":\"fixture\"}".utf8))] {
        f.profile.set { _ in reply }; await #expect(throws: (any Error).self) { try await f.oauth().accessToken() }
        #expect(await f.secrets.values["google-tokens"] == original)
    }
    f.profile.set { _ in OAuthHTTPReply(body: Data(repeating: 32, count: 65537)) }
    await #expect(throws: (any Error).self) { try await f.oauth().revoke() }
    #expect(await f.secrets.values["google-tokens"] == original)
}

@Test func googleTransportDeniesRedirectsAndEnforcesActualResourceDeadlineOnLoopback() async throws {
    let sink = try GoogleLocalHTTP(response: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)); defer { sink.stop() }
    let source = try GoogleLocalHTTP(response: Data("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(sink.port)/must-not-receive-secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); defer { source.stop() }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(source.port)/token")!); request.httpMethod = "POST"; request.httpBody = Data("client_secret=fixture-only".utf8)
    await #expect(throws: (any Error).self) { try await GoogleTokenHTTP(configuration: nil).request(request) }
    #expect(source.count == 1 && sink.count == 0)
    let stalled = try GoogleLocalHTTP(response: nil); defer { stalled.stop() }
    let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 0.1; config.timeoutIntervalForRequest = 0.1
    request.url = URL(string: "http://127.0.0.1:\(stalled.port)/token")
    let started = ProcessInfo.processInfo.systemUptime
    await #expect(throws: (any Error).self) { try await GoogleTokenHTTP(configuration: config).request(request) }
    #expect(ProcessInfo.processInfo.systemUptime - started < 2)
}

@Test func googleLateRefreshCannotOverwriteNewAccountForSameClient() async throws {
    let f = try OAuthFixture(); defer { f.clean() }
    let second = f.oauth(authorization: { _ in "new-account-fixture-code" })
    let newerAccess = "new-account-access-" + UUID().uuidString, newerRefresh = "new-account-refresh-" + UUID().uuidString
    let newer = try OAuthHTTPReply.tokens(newerAccess, refresh: newerRefresh), older = try OAuthHTTPReply.tokens(f.access)
    f.profile.set { request in
        if OAuthHTTPProtocol.fields(request)["grant_type"] == "refresh_token" { try await second.signIn(); return older }
        return newer
    }
    await #expect(throws: (any Error).self) { try await f.oauth().accessToken() }
    #expect(try await second.accessToken() == newerAccess)
    let stored = try #require(await f.secrets.values["google-tokens"]), value = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(value["accessToken"] as? String == newerAccess && value["refreshToken"] as? String == newerRefresh)
}

@Test func googleLateRevokeNeverRemovesAnotherActorsNewClientTokens() async throws {
    let f = try OAuthFixture(), other = try OAuthFixture(legacy: false); defer { f.clean(); other.clean() }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthHTTPProtocol.self]
    let second = GoogleOAuth(secrets: f.secrets, configuration: config, authorization: { _ in "fixture-code" })
    let newClient = try JSONDecoder().decode(OAuthClient.self, from: other.clientData), path = try f.document(newClient, name: "replacement.json")
    let newer = try OAuthHTTPReply.tokens(other.access, refresh: other.refresh); other.profile.set { _ in newer }
    f.profile.set { _ in try await second.importClient(from: path); try await second.signIn(); return OAuthHTTPReply(body: Data()) }
    await #expect(throws: (any Error).self) { try await f.oauth().revoke() }
    #expect(try await second.accessToken() == other.access)
}

@Test func googleRevokeWithoutStoredGrantIsIdempotentAndDoesNotContactGoogle() async throws {
    let secrets = TestSecrets()
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthHTTPProtocol.self]
    let oauth = GoogleOAuth(secrets: secrets, configuration: config)
    try await oauth.revoke(); try await oauth.revoke()
    #expect(await oauth.isConnected() == false)
}
