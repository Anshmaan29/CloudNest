import Testing
import Foundation
@testable import CloudNestCore

@Test func onboardingCheckpointResumesWithoutClaimingAnUnverifiedRestore() throws {
    let name = "CloudNest.OnboardingTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var progress = OnboardingProgress()
    progress.advance(); progress.advance(); progress.safetyReviewed = true
    let first = UUID(); progress.selectedArchive(first)
    try progress.save(to: defaults)
    let restored = try OnboardingProgress.load(from: defaults)
    #expect(restored == progress)
    #expect(restored.archiveJobID == first)
    #expect(restored.restoreProof == nil)
    var protectedNavigation = restored
    protectedNavigation.visit(.restore)
    #expect(protectedNavigation.step == .folders)
    defaults.set(Data("{\"schemaVersion\":99}".utf8), forKey: OnboardingProgress.defaultsKey)
    #expect(throws: (any Error).self) { try OnboardingProgress.load(from: defaults) }
}

@Test func publicGoogleConfigurationRefusesSecretsEndpointsAndWrongClientTypes() throws {
    let valid: [String: Any] = ["schemaVersion": 1, "clientID": "123456789012-generatedfixture.apps.googleusercontent.com"]
    let configuration = try BundledGoogleClient(data: JSONSerialization.data(withJSONObject: valid))
    #expect(configuration.clientID == valid["clientID"] as? String)
    for field in ["client_secret", "refresh_token", "access_token", "token_uri", "web"] {
        var bad = valid; bad[field] = "fixture-value"
        #expect(throws: (any Error).self) { try BundledGoogleClient(data: JSONSerialization.data(withJSONObject: bad)) }
    }
    #expect(throws: (any Error).self) { try BundledGoogleClient(data: Data("{\"schemaVersion\":true,\"clientID\":\"123456789012-generatedfixture.apps.googleusercontent.com\"}".utf8)) }
    #expect(throws: (any Error).self) { try BundledGoogleClient(data: Data("{\"schemaVersion\":1,\"clientID\":\"https://example.invalid\"}".utf8)) }
}

@Test func checkingPublicClientReadinessPreservesExistingKeychainGrant() async throws {
    let secrets = TestSecrets()
    let client = Data("{\"client_id\":\"123456789012-existingfixture.apps.googleusercontent.com\",\"client_secret\":\"fixture-client-secret\"}".utf8)
    let tokens = Data("existing-fixture-grant".utf8)
    await secrets.write("google-client", value: client); await secrets.write("google-tokens", value: tokens)
    #expect(try await BundledGoogleClient.hasSavedClient(in: secrets))
    #expect(await secrets.read("google-client") == client)
    #expect(await secrets.read("google-tokens") == tokens)
}

@Test func explicitPublicClientInstallUsesExistingImportTransactionWithoutBundlingASecret() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let configuration = try BundledGoogleClient(data: Data("{\"schemaVersion\":1,\"clientID\":\"123456789012-generatedfixture.apps.googleusercontent.com\"}".utf8))
    await fixture.secrets.write("google-tokens", value: Data("old-fixture-grant".utf8))
    try await configuration.install(into: GoogleOAuth(secrets: fixture.secrets), stagingDirectory: fixture.base.appendingPathComponent("public-client"))
    let data = try #require(await fixture.secrets.read("google-client"))
    let imported = try JSONDecoder().decode(OAuthClient.self, from: data)
    #expect(imported.client_id == configuration.clientID)
    #expect(imported.client_secret == nil)
    #expect(await fixture.secrets.read("google-tokens") == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.appendingPathComponent("public-client").path).isEmpty)
}

@Test func introductoryArchiveEnforcesApprovedRootsAndPersistsIdentityBeforeUpload() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let roundTrip = OnboardingRoundTrip(catalog: fixture.catalog, remote: fixture.remote, secrets: fixture.secrets)
    await #expect(throws: (any Error).self) { try await roundTrip.archive(source: fixture.source, approvedRoots: []) }
    #expect(await fixture.remote.objects.isEmpty)
    await fixture.remote.configure(interrupt: true)
    let receipt = OnboardingEnqueueReceipt()
    await #expect(throws: (any Error).self) {
        try await roundTrip.archive(source: fixture.source, approvedRoots: [fixture.base], onEnqueued: { job in await receipt.save(job.id) })
    }
    let id = try #require(await receipt.id)
    #expect(try await fixture.catalog.job(id).state != .verified)
    let resumed = try await roundTrip.resume(id, approvedRoots: [fixture.base])
    #expect(resumed.state == .verified)
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(await fixture.remote.sentOffsets == [0])
}
private actor OnboardingEnqueueReceipt { var id: UUID?; func save(_ id: UUID) { self.id = id } }

@Test func introductoryRestoreRequiresRealMatchingBytesAndNeverOverwritesOrRemovesOriginal() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let roundTrip = OnboardingRoundTrip(catalog: fixture.catalog, remote: fixture.remote, secrets: fixture.secrets)
    let job = try await roundTrip.archive(source: fixture.source, approvedRoots: [fixture.base])
    let destination = fixture.base.appendingPathComponent("verified-restore")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    await fixture.remote.configure(download: true)
    await #expect(throws: (any Error).self) { try await roundTrip.restore(job.id, destination: destination) }
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(fixture.source.lastPathComponent).path))
    await fixture.remote.configure()
    let proof = try await roundTrip.restore(job.id, destination: destination)
    #expect(try await roundTrip.validate(proof))
    #expect(try Data(contentsOf: proof.restoredURL) == Data(contentsOf: fixture.source))
    await #expect(throws: (any Error).self) { try await roundTrip.restore(job.id, destination: destination) }
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    try Data("changed generated fixture".utf8).write(to: proof.restoredURL)
    #expect(try await roundTrip.validate(proof) == false)
}
