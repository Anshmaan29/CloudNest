import Foundation
import AppKit
import CryptoKit
import Security
import Darwin

public struct OAuthClient: Codable, Sendable {
    public let client_id: String
    public let client_secret: String?
}
private struct Credential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let clientID: String?
    let clientFingerprint: String?
}
private struct TokenReply: Decodable, Sendable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double
    let scope: String?
    let token_type: String?
}

// One lease covers only local credential reads/writes, never browser/network waits.
// This keeps multiple GoogleOAuth actors from interleaving a client import and save.
private actor GoogleCredentialGate {
    static let shared = GoogleCredentialGate()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async { if held { await withCheckedContinuation { waiting.append($0) } } else { held = true } }
    func release() { if waiting.isEmpty { held = false } else { waiting.removeFirst().resume() } }
}
private func googleCredentialTransaction<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation(); await GoogleCredentialGate.shared.acquire()
    do { try Task.checkCancellation(); let result = try await operation(); await GoogleCredentialGate.shared.release(); return result }
    catch { await GoogleCredentialGate.shared.release(); throw error }
}
private final class GoogleRequestCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var task: URLSessionTask?; private var cancelled = false
    func register(_ value: URLSessionTask) { lock.lock(); task = value; let stop = cancelled; lock.unlock(); if stop { value.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let value = task; lock.unlock(); value?.cancel() }
}
private final class GoogleResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var data = Data()
        var response: HTTPURLResponse?
        let completion: CheckedContinuation<Data, any Error>
        let deadline: DispatchWorkItem
    }
    private let lock = NSLock(); private var pending: [Int: Pending] = [:]
    func register(_ task: URLSessionTask, completion: CheckedContinuation<Data, any Error>, timeout: TimeInterval) {
        let deadline = DispatchWorkItem { [weak self, weak task] in
            guard let task else { return }; self?.finish(task.taskIdentifier, error: URLError(.timedOut)); task.cancel()
        }
        lock.lock(); pending[task.taskIdentifier] = Pending(completion: completion, deadline: deadline); lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
    }
    private func finish(_ id: Int, error: (any Error)? = nil) {
        lock.lock(); let value = pending.removeValue(forKey: id); lock.unlock()
        guard let value else { return }; value.deadline.cancel()
        if let error { value.completion.resume(throwing: error) }
        else if value.response != nil { value.completion.resume(returning: value.data) }
        else { value.completion.resume(throwing: NestError.invalidResponse) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == dataTask.originalRequest?.url else { finish(dataTask.taskIdentifier, error: NestError.invalidResponse); completionHandler(.cancel); return }
        guard response.statusCode == 200 else { finish(dataTask.taskIdentifier, error: NestError.http(response.statusCode)); completionHandler(.cancel); return }
        guard response.expectedContentLength <= 65536 else { finish(dataTask.taskIdentifier, error: NestError.invalidResponse); completionHandler(.cancel); return }
        lock.lock(); if pending[dataTask.taskIdentifier] != nil { pending[dataTask.taskIdentifier]?.response = response }; lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let count = pending[dataTask.taskIdentifier]?.data.count else { lock.unlock(); return }
        if data.count > 65536 - count { lock.unlock(); finish(dataTask.taskIdentifier, error: NestError.invalidResponse); dataTask.cancel(); return }
        pending[dataTask.taskIdentifier]?.data.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) { finish(task.taskIdentifier, error: error) }
}
final class GoogleTokenHTTP: @unchecked Sendable {
    private let delegate: GoogleResponseDelegate
    private let session: URLSession
    private let resourceDeadline: TimeInterval
    init(configuration: URLSessionConfiguration?) {
        let config = URLSessionConfiguration.ephemeral
        if let configuration { config.protocolClasses = configuration.protocolClasses }
        config.timeoutIntervalForRequest = min(30, max(0.05, configuration?.timeoutIntervalForRequest ?? 30))
        config.timeoutIntervalForResource = min(60, max(0.05, configuration?.timeoutIntervalForResource ?? 60))
        resourceDeadline = config.timeoutIntervalForResource
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        delegate = GoogleResponseDelegate(); session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func request(_ request: URLRequest) async throws -> Data {
        let cancellation = GoogleRequestCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request); delegate.register(task, completion: continuation, timeout: resourceDeadline)
                cancellation.register(task); task.resume()
            }
        }, onCancel: { cancellation.cancel() })
    }
}


public enum PKCE {
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NestError.credentialUnavailable }
        return encode(Data(bytes))
    }
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func challenge(_ verifier: String) -> String { encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public static func callbackCode(_ target: String, expectedState: String) throws -> String {
        guard let parts = URLComponents(string: "http://127.0.0.1" + target), parts.path == "/callback",
              parts.queryItems?.filter({ $0.name == "state" }).count == 1,
              parts.queryItems?.first(where: { $0.name == "state" })?.value == expectedState,
              parts.queryItems?.filter({ $0.name == "code" }).count == 1,
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw NestError.credentialUnavailable }
        return code
    }
}

// One short-lived listener, bound exclusively to IPv4 loopback. Never a permanent server.
private final class OAuthLoopback: @unchecked Sendable {
    let descriptor: Int32
    let port: UInt16
    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw NestError.credentialUnavailable }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(socketFD, 4) == 0 else { close(socketFD); throw NestError.credentialUnavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        descriptor = socketFD; port = UInt16(bigEndian: address.sin_port)
    }
    deinit { close(descriptor) }
    func receive(state: String) throws -> String {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptorPoll, 1, 250) > 0 else { continue }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = recv(client, &bytes, bytes.count, 0)
            guard count > 0 else { continue }
            let request = String(decoding: bytes.prefix(count), as: UTF8.self)
            let first = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            let code = first.count == 3 && first[0] == "GET" ? try? PKCE.callbackCode(String(first[1]), expectedState: state) : nil
            let body = code == nil ? "Authorization was not accepted. Return to CloudNest." : "Connected. You can close this tab and return to CloudNest."
            let response = "HTTP/1.1 \(code == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            response.withCString { pointer in _ = send(client, pointer, strlen(pointer), 0) }
            if let code { return code }
        }
        throw NestError.credentialUnavailable
    }
}

public actor GoogleOAuth {
    public static let scope = "https://www.googleapis.com/auth/drive.file"
    private let secrets: any SecretStore
    private let http: GoogleTokenHTTP
    private let authorization: (@Sendable (URL) async throws -> String)?
    private var signingIn = false
    private var refreshing: (id: UUID, task: Task<String, any Error>)?
    public init(secrets: any SecretStore = KeychainStore(), configuration: URLSessionConfiguration? = nil, authorization: (@Sendable (URL) async throws -> String)? = nil) {
        self.secrets = secrets; http = GoogleTokenHTTP(configuration: configuration); self.authorization = authorization
    }
    private struct Context: Sendable { let client: OAuthClient; let clientData: Data; let tokens: Data? }
    private static func validClient(_ client: OAuthClient) throws {
        // Google's Desktop-app download uses an installed section. Never trust
        // provider endpoints from the imported JSON; all endpoints stay fixed.
        guard client.client_id.utf8.count <= 200,
              client.client_id.range(of: "^[0-9]{6,30}(?:-[A-Za-z0-9_-]{6,128})?\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil,
              client.client_secret.map({ (8...512).contains($0.utf8.count) && $0.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 } }) ?? true else { throw NestError.notConfigured }
    }
    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func readClient(_ secrets: any SecretStore) async throws -> Context {
        guard let data = try await secrets.read("google-client"), data.count <= 131072 else { throw NestError.notConfigured }
        let client = try JSONDecoder().decode(OAuthClient.self, from: data); try validClient(client)
        let tokens = try await secrets.read("google-tokens")
        guard tokens.map({ $0.count <= 65536 }) ?? true else { throw NestError.credentialUnavailable }
        return Context(client: client, clientData: data, tokens: tokens)
    }
    private static func token(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 16384 && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 } }
    private static func credential(_ data: Data) throws -> Credential {
        guard data.count <= 65536 else { throw NestError.credentialUnavailable }
        let value = try JSONDecoder().decode(Credential.self, from: data)
        guard token(value.accessToken), value.refreshToken.map(token) ?? true, value.expiresAt.timeIntervalSinceReferenceDate.isFinite else { throw NestError.credentialUnavailable }; return value
    }
    private func context() async throws -> Context { let store = secrets; return try await googleCredentialTransaction { try await Self.readClient(store) } }
    public func importClient(from url: URL) async throws {
        // Validate before touching any existing grant. Descriptor walking rejects
        // symlink ancestors; O_NONBLOCK also prevents FIFO/device reads hanging.
        guard url.isFileURL, url.query == nil, url.fragment == nil, url.host == nil || url.host == "" || url.host == "localhost" else { throw NestError.notConfigured }
        let parent = try FileSafety.openDirectory(url.deletingLastPathComponent()); defer { close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NestError.notConfigured }; defer { close(descriptor) }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_flags & UInt32(SF_DATALESS) == 0, before.st_size > 0, before.st_size <= 131072 else { throw NestError.notConfigured }
        var data = Data(); data.reserveCapacity(Int(before.st_size)); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation(); let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw NestError.notConfigured }; if count == 0 { break }
            guard data.count <= 131072 - count else { throw NestError.notConfigured }; data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(descriptor, &after) == 0, FileSafety.identity(before) == FileSafety.identity(after), Int64(data.count) == before.st_size else { throw NestError.sourceChanged }
        struct Document: Decodable { let installed: OAuthClient }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard root?["web"] == nil, root?["installed"] != nil else { throw NestError.notConfigured }
        let client = try JSONDecoder().decode(Document.self, from: data).installed; try Self.validClient(client)
        struct Imported: Encodable { let client_id: String; let client_secret: String?; let cloudnestImportID: UUID }
        let encoded = try JSONEncoder().encode(Imported(client_id: client.client_id, client_secret: client.client_secret, cloudnestImportID: UUID()))
        let store = secrets
        refreshing?.task.cancel()
        try await googleCredentialTransaction {
            // Import intentionally clears old tokens, including a same-ID import.
            try await store.remove("google-tokens"); try await store.write("google-client", value: encoded)
        }
    }
    public func isConnected() async -> Bool {
        guard let current = try? await context(), let data = current.tokens, let stored = try? Self.credential(data) else { return false }
        guard stored.clientID == nil || stored.clientID == current.client.client_id else { return false }
        guard stored.clientFingerprint == nil || stored.clientFingerprint == Self.fingerprint(current.clientData) else { return false }
        return stored.refreshToken != nil || (stored.clientID != nil && stored.clientFingerprint != nil && stored.expiresAt.timeIntervalSinceNow > 90)
    }
    public func signIn() async throws {
        guard !signingIn else { throw NestError.busy }; signingIn = true; defer { signingIn = false }
        let captured = try await context(), config = captured.client
        let receiver = authorization == nil ? try OAuthLoopback() : nil
        let verifier = try PKCE.random(), state = try PKCE.random()
        let redirect = "http://127.0.0.1:\(receiver?.port ?? 1)/callback"
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let parameters = ["client_id": config.client_id, "redirect_uri": redirect, "response_type": "code", "scope": Self.scope,
                          "state": state, "code_challenge": PKCE.challenge(verifier), "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent"]
        url.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }; guard let authorizationURL = url.url else { throw NestError.invalidResponse }
        let code: String
        if let authorization { code = try await authorization(authorizationURL) }
        else {
            guard let receiver else { throw NestError.credentialUnavailable }
            let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }; guard opened else { throw NestError.credentialUnavailable }
            let callback = Task.detached { try receiver.receive(state: state) }
            code = try await withTaskCancellationHandler(operation: { try await callback.value }, onCancel: { callback.cancel() })
        }
        guard Self.token(code), code.utf8.count <= 8192 else { throw NestError.credentialUnavailable }
        try await ensureCurrent(captured)
        var fields = ["client_id": config.client_id, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"]
        fields["client_secret"] = config.client_secret
        let reply = try await tokenRequest(fields)
        guard reply.scope?.split(separator: " ").contains(Substring(Self.scope)) == true else { throw NestError.credentialUnavailable }
        try await save(reply, previousRefresh: nil, expected: captured)
    }
    public func accessToken() async throws -> String {
        if let refreshing { return try await refreshing.task.value }
        let captured = try await context(); guard let data = captured.tokens else { throw NestError.credentialUnavailable }
        let stored = try Self.credential(data)
        guard stored.clientID == nil || stored.clientID == captured.client.client_id,
              stored.clientFingerprint == nil || stored.clientFingerprint == Self.fingerprint(captured.clientData) else { throw NestError.credentialUnavailable }
        // Legacy tokens are never trusted solely because the cache is unexpired.
        // A successful refresh validates the current Desktop client before binding.
        if stored.clientID != nil, stored.clientFingerprint != nil, stored.expiresAt.timeIntervalSinceNow > 90, stored.expiresAt.timeIntervalSinceNow <= 86400 { return stored.accessToken }
        guard stored.refreshToken != nil else { throw NestError.credentialUnavailable }
        if let refreshing { return try await refreshing.task.value }
        let id = UUID(), task = Task { try await self.refresh(captured) }; refreshing = (id, task)
        defer { if refreshing?.id == id { refreshing = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func refresh(_ captured: Context) async throws -> String {
        guard let data = captured.tokens, let refresh = try Self.credential(data).refreshToken else { throw NestError.credentialUnavailable }
        var fields = ["client_id": captured.client.client_id, "grant_type": "refresh_token", "refresh_token": refresh]; fields["client_secret"] = captured.client.client_secret
        let reply = try await tokenRequest(fields)
        if let scope = reply.scope { guard scope.split(separator: " ").contains(Substring(Self.scope)) else { throw NestError.credentialUnavailable } }
        try await save(reply, previousRefresh: refresh, expected: captured); return reply.access_token
    }
    private func ensureCurrent(_ expected: Context) async throws {
        let store = secrets
        try await googleCredentialTransaction { let current = try await Self.readClient(store); guard current.client.client_id == expected.client.client_id, current.clientData == expected.clientData, current.tokens == expected.tokens else { throw NestError.credentialUnavailable } }
    }
    private func save(_ reply: TokenReply, previousRefresh: String?, expected: Context) async throws {
        let credentials = Credential(accessToken: reply.access_token, refreshToken: reply.refresh_token ?? previousRefresh, expiresAt: Date().addingTimeInterval(reply.expires_in), clientID: expected.client.client_id, clientFingerprint: Self.fingerprint(expected.clientData))
        let data = try JSONEncoder().encode(credentials), store = secrets
        try await googleCredentialTransaction {
            let current = try await Self.readClient(store)
            guard current.client.client_id == expected.client.client_id, current.clientData == expected.clientData, current.tokens == expected.tokens else { throw NestError.credentialUnavailable }
            try await store.write("google-tokens", value: data)
            let after = try await Self.readClient(store)
            guard after.client.client_id == expected.client.client_id, after.clientData == expected.clientData, after.tokens == data else { throw NestError.credentialUnavailable }
        }
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> TokenReply {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Self.form(fields)
        let reply = try JSONDecoder().decode(TokenReply.self, from: await http.request(request))
        guard Self.token(reply.access_token), reply.refresh_token.map(Self.token) ?? true, reply.expires_in.isFinite, reply.expires_in > 0, reply.expires_in <= 86400,
              reply.token_type.map({ $0.lowercased() == "bearer" }) ?? true,
              reply.scope.map({ $0.utf8.count <= 4096 && $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value <= 126 } }) ?? true else { throw NestError.invalidResponse }
        return reply
    }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    public func revoke() async throws {
        let store = secrets
        let context: Context? = try await googleCredentialTransaction {
            guard try await store.read("google-tokens") != nil else { return nil }
            return try await Self.readClient(store)
        }
        guard let captured = context, let data = captured.tokens else { return }; let credentials = try Self.credential(data)
        guard credentials.clientID == nil || credentials.clientID == captured.client.client_id,
              credentials.clientFingerprint == nil || credentials.clientFingerprint == Self.fingerprint(captured.clientData) else { throw NestError.credentialUnavailable }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Self.form(["token": credentials.refreshToken ?? credentials.accessToken])
        _ = try await http.request(request)
        try await googleCredentialTransaction { let current = try await Self.readClient(store); guard current.clientData == captured.clientData, current.tokens == captured.tokens else { throw NestError.credentialUnavailable }; try await store.remove("google-tokens") }
    }
}
