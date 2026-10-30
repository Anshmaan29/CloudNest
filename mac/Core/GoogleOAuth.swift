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
}
private struct TokenReply: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double
    let scope: String?
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
    private var signingIn = false
    public init(secrets: any SecretStore = KeychainStore()) { self.secrets = secrets }
    public func importClient(from url: URL) async throws {
        struct Document: Decodable { let installed: OAuthClient }
        let client = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)).installed
        guard client.client_id.hasSuffix(".apps.googleusercontent.com") else { throw NestError.notConfigured }
        // Changing OAuth identity must not accidentally reuse the previous account's tokens.
        try await secrets.remove("google-tokens")
        try await secrets.write("google-client", value: JSONEncoder().encode(client))
    }
    private func client() async throws -> OAuthClient {
        guard let data = try await secrets.read("google-client") else { throw NestError.notConfigured }
        return try JSONDecoder().decode(OAuthClient.self, from: data)
    }
    public func isConnected() async -> Bool { (try? await secrets.read("google-tokens")) != nil }
    public func signIn() async throws {
        guard !signingIn else { throw NestError.busy }
        signingIn = true; defer { signingIn = false }
        let config = try await client(), receiver = try OAuthLoopback()
        let verifier = try PKCE.random(), state = try PKCE.random()
        let redirect = "http://127.0.0.1:\(receiver.port)/callback"
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let parameters = ["client_id": config.client_id, "redirect_uri": redirect, "response_type": "code", "scope": Self.scope,
                          "state": state, "code_challenge": PKCE.challenge(verifier), "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent"]
        url.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let authorizationURL = url.url else { throw NestError.invalidResponse }
        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        guard opened else { throw NestError.credentialUnavailable }
        let code = try await Task.detached { try receiver.receive(state: state) }.value
        var fields = ["client_id": config.client_id, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"]
        fields["client_secret"] = config.client_secret
        let reply = try await tokenRequest(fields)
        guard reply.scope?.split(separator: " ").contains(Substring(Self.scope)) == true else { throw NestError.credentialUnavailable }
        try await save(reply, previousRefresh: nil)
    }
    public func accessToken() async throws -> String {
        guard let data = try await secrets.read("google-tokens") else { throw NestError.credentialUnavailable }
        let stored = try JSONDecoder().decode(Credential.self, from: data)
        if stored.expiresAt.timeIntervalSinceNow > 90 { return stored.accessToken }
        guard let refresh = stored.refreshToken else { throw NestError.credentialUnavailable }
        let config = try await client()
        var fields = ["client_id": config.client_id, "grant_type": "refresh_token", "refresh_token": refresh]
        fields["client_secret"] = config.client_secret
        let reply = try await tokenRequest(fields)
        try await save(reply, previousRefresh: refresh)
        return reply.access_token
    }
    private func save(_ reply: TokenReply, previousRefresh: String?) async throws {
        let credentials = Credential(accessToken: reply.access_token, refreshToken: reply.refresh_token ?? previousRefresh, expiresAt: Date().addingTimeInterval(reply.expires_in))
        try await secrets.write("google-tokens", value: JSONEncoder().encode(credentials))
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> TokenReply {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NestError.invalidResponse }
        guard response.statusCode == 200 else { throw NestError.http(response.statusCode) }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    public func revoke() async throws {
        guard let data = try await secrets.read("google-tokens") else { return }
        let credentials = try JSONDecoder().decode(Credential.self, from: data)
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": credentials.refreshToken ?? credentials.accessToken])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NestError.credentialUnavailable }
        try await secrets.remove("google-tokens")
    }
}
