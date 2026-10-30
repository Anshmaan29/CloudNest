import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(_ key: String) async throws -> Data?
    func write(_ key: String, value: Data) async throws
    func remove(_ key: String) async throws
}

public struct KeychainStore: SecretStore {
    public let service: String
    public init(service: String = "org.cloudnest.os") { self.service = service }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    public func read(_ key: String) async throws -> Data? {
        try await Task.detached(priority: .utility) { try readSynchronously(key) }.value
    }
    private func readSynchronously(_ key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NestError.credentialUnavailable }
        return data
    }
    public func write(_ key: String, value: Data) async throws {
        try await Task.detached(priority: .utility) { try writeSynchronously(key, value: value) }.value
    }
    private func writeSynchronously(_ key: String, value: Data) throws {
        let q = query(key)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw NestError.credentialUnavailable }
        } else if status != errSecSuccess { throw NestError.credentialUnavailable }
    }
    public func remove(_ key: String) async throws {
        try await Task.detached(priority: .utility) { try removeSynchronously(key) }.value
    }
    private func removeSynchronously(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NestError.credentialUnavailable }
    }
}
