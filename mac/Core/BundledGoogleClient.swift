import Foundation

/// Release metadata for a public Desktop OAuth client. Personal clients, tokens,
/// client secrets, and provider endpoint overrides are deliberately unsupported.
public struct BundledGoogleClient: Sendable, Equatable {
    public let clientID: String
    public init(data: Data) throws {
        guard data.count <= 4096 else { throw NestError.notConfigured }
        struct Document: Decodable { let schemaVersion: Int; let clientID: String }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "clientID"],
              document.schemaVersion == 1,
              let id = object["clientID"] as? String,
              id.utf8.count <= 200,
              id.range(of: "^[0-9]{6,30}(?:-[A-Za-z0-9_-]{6,128})?\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil else { throw NestError.notConfigured }
        clientID = id
    }
    public static func load(from bundle: Bundle = .main) throws -> Self? {
        guard let url = bundle.url(forResource: "CloudNestGoogleClient", withExtension: "json") else { return nil }
        return try Self(data: Data(contentsOf: url, options: .mappedIfSafe))
    }
    /// Explicit user action only. GoogleOAuth's existing import transaction clears
    /// the prior grant; callers must ask before replacing an existing client.
    public func install(into oauth: GoogleOAuth, stagingDirectory: URL) async throws {
        let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("public-desktop-client.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["installed": ["client_id": clientID]])
        guard FileManager.default.createFile(atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw NestError.notConfigured }
        try await oauth.importClient(from: url)
    }
    public static func hasSavedClient(in secrets: any SecretStore = KeychainStore()) async throws -> Bool {
        guard let data = try await secrets.read("google-client") else { return false }
        guard data.count <= 131072 else { throw NestError.notConfigured }
        _ = try JSONDecoder().decode(OAuthClient.self, from: data)
        return true
    }
}
