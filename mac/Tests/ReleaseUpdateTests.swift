import Testing
import Foundation
import CryptoKit
import Darwin
@testable import CloudNestCore

private final class UpdateProtocol: URLProtocol, @unchecked Sendable {
    enum Action { case bytes(Data, Int = 200), redirect(URL) }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [URL: Action] = [:]
    nonisolated(unsafe) private static var requests: [URL: URLRequest] = [:]
    static func add(_ url: URL, _ action: Action) { lock.lock(); routes[url] = action; lock.unlock() }
    static func seen(_ url: URL) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return requests[url] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let action = request.url.flatMap { Self.routes[$0] }; if let url = request.url { Self.requests[url] = request }; Self.lock.unlock()
        guard let action, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        switch action {
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location":target.absoluteString])!
            var forwarded = URLRequest(url: target); forwarded.setValue("must-not-forward", forHTTPHeaderField: "Authorization"); forwarded.setValue("private-cookie", forHTTPHeaderField: "Cookie")
            client?.urlProtocol(self, wasRedirectedTo: forwarded, redirectResponse: response)
        case .bytes(let data, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Length":String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for offset in stride(from: 0, to: data.count, by: 65536) { client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 65536, data.count))) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
private struct UpdateFixture {
    let key = Curve25519.Signing.PrivateKey()
    let suffix = UUID().uuidString
    var feed: URL { URL(string: "https://github.com/Anshmaan29/CloudNest/releases/latest/download/feed-\(suffix).json")! }
    var asset: URL { URL(string: "https://github.com/Anshmaan29/CloudNest/releases/download/v1.2.3/CloudNest-\(suffix).zip")! }
    let bytes = Data(repeating: 0x5a, count: 200_000)
    var configuration: ReleaseUpdateConfiguration { get throws { try .init(publicKey: key.publicKey.rawRepresentation, teamID: "ABC1234567", feedURL: feed) } }
    var service: ReleaseUpdate { get throws { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdateProtocol.self]; return try .init(configuration: configuration, sessionConfiguration: config) } }
    func envelope(_ changes: [String: Any] = [:], extra: Bool = false) throws -> Data {
        let formatter = ISO8601DateFormatter()
        var raw: [String: Any] = ["schemaVersion":1,"version":"1.2.3","build":"123","minimumMacOS":"14.0","architectures":["arm64","x86_64"],"assetURL":asset.absoluteString,"bytes":bytes.count,"sha256":SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined(),"publishedAt":formatter.string(from: Date().addingTimeInterval(-60)),"expiresAt":formatter.string(from: Date().addingTimeInterval(3600))]
        for (key, value) in changes { raw[key] = value }
        let payload = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        var envelope: [String: Any] = ["payload":payload.base64EncodedString(),"signature":try key.signature(for: payload).base64EncodedString()]
        if extra { envelope["unknown"] = true }
        return try JSONSerialization.data(withJSONObject: envelope)
    }
    var runtime: ReleaseUpdateRuntime { .init(architecture: "arm64", macOS: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)) }
    func root() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.deletingLastPathComponent().appendingPathComponent("release-tests-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700]); return root
    }
}
@Test func updateSemanticVersionOrderingAndInvalidVersions() throws {
    let ordered = ["1.0.0-alpha","1.0.0-alpha.1","1.0.0-alpha.beta","1.0.0-beta","1.0.0-beta.2","1.0.0-beta.11","1.0.0-rc.1","1.0.0","1.2.0","2.0.0"]
    for (a,b) in zip(ordered, ordered.dropFirst()) { #expect(try ReleaseVersion(a) < ReleaseVersion(b)) }
    #expect(try ReleaseVersion("1.0.0+one") == ReleaseVersion("1.0.0+two"))
    for invalid in ["1.0", "01.0.0", "1.0.0-01", "1.0.0-", "v1.0.0", "1.2.3\n", "99999999999.0.0"] { #expect(throws: (any Error).self) { try ReleaseVersion(invalid) } }
}
@Test func updateSignedManifestAuthenticatesAndRejectsTamperingWrongKeysAndUnknownFields() throws {
    let f = UpdateFixture(), data = try f.envelope(), service = try f.service
    #expect(try service.verify(data, currentVersion:"0.5.0",runtime:f.runtime)?.manifest.version == "1.2.3")
    var altered = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var payload = Data(base64Encoded: altered["payload"] as! String)!; payload[payload.count / 2] ^= 1; altered["payload"] = payload.base64EncodedString()
    #expect(throws: (any Error).self) { try service.verify(JSONSerialization.data(withJSONObject:altered),currentVersion:"0.5.0",runtime:f.runtime) }
    let other = UpdateFixture(); #expect(throws:(any Error).self) { try other.service.verify(data,currentVersion:"0.5.0",runtime:f.runtime) }
    #expect(throws:(any Error).self) { try service.verify(f.envelope(extra:true),currentVersion:"0.5.0",runtime:f.runtime) }
    #expect(throws:(any Error).self) { try service.verify(f.envelope(["extra":"field"]),currentVersion:"0.5.0",runtime:f.runtime) }
}
@Test func updateManifestRejectsIncompatibleExpiredOversizedAndDowngradeOffers() throws {
    let f = UpdateFixture(), service = try f.service
    #expect(try service.verify(f.envelope(),currentVersion:"1.2.3",runtime:f.runtime) == nil)
    #expect(try service.verify(f.envelope(),currentVersion:"2.0.0",runtime:f.runtime) == nil)
    for change: [String: Any] in [["architectures":["x86_64"]],["minimumMacOS":"16.0"],["bytes":209715201],["bytes":0],["expiresAt":"2020-01-01T00:00:00Z"],["assetURL":"https://attacker.example.invalid/update.zip"],["sha256":"bad"],["minimumMacOS":"14"],["schemaVersion":true]] {
        #expect(throws:(any Error).self) { try service.verify(f.envelope(change),currentVersion:"0.5.0",runtime:f.runtime) }
    }
}
@Test func updateRedirectPolicyAcceptsGitHubDeliveryAndRejectsHostDowngradeLoopsAndExcessHops() throws {
    let f = UpdateFixture(), versioned = URL(string:"https://github.com/Anshmaan29/CloudNest/releases/download/v1.2.3/feed.json")!, cdn = URL(string:"https://release-assets.githubusercontent.com/github-production-release-asset/123/12345678-1234-1234-1234-123456789abc?opaque=fixture")!
    var policy = try ReleaseRedirectPolicy(initial:f.feed); try policy.accept(from:f.feed,to:versioned); try policy.accept(from:versioned,to:cdn)
    #expect(policy.hops == 2)
    #expect(throws:(any Error).self) { try policy.accept(from:cdn,to:f.asset) }
    for target in ["http://github.com/Anshmaan29/CloudNest/releases/download/v1.2.3/app.zip","https://evil.example.invalid/app.zip","https://github.com/Other/Repo/releases/download/v1/app.zip","https://user:pass@github.com/Anshmaan29/CloudNest/releases/download/v1/app.zip","https://release-assets.githubusercontent.com/other/path"] {
        var denied = try ReleaseRedirectPolicy(initial:f.feed); #expect(throws:(any Error).self) { try denied.accept(from:f.feed,to:URL(string:target)!) }
    }
    var loop = try ReleaseRedirectPolicy(initial:f.feed); try loop.accept(from:f.feed,to:f.asset); #expect(throws:(any Error).self) { try loop.accept(from:f.asset,to:f.feed) }
    let third = URL(string:"https://github.com/Anshmaan29/CloudNest/releases/download/v1.2.3/third.zip")!, fourth = URL(string:"https://github.com/Anshmaan29/CloudNest/releases/download/v1.2.3/fourth.zip")!
    var capped = try ReleaseRedirectPolicy(initial:f.feed); try capped.accept(from:f.feed,to:f.asset); try capped.accept(from:f.asset,to:third); try capped.accept(from:third,to:fourth)
    #expect(throws:(any Error).self) { try capped.accept(from:fourth,to:cdn) }
}
@Test func updateSyntheticNetworkDownloadsPrivatelyAndChecksExactDigestAndSize() async throws {
    let f = UpdateFixture(), root = try f.root(); defer { try? FileManager.default.removeItem(at:root) }
    UpdateProtocol.add(f.feed,.bytes(try f.envelope())); UpdateProtocol.add(f.asset,.bytes(f.bytes))
    let release = try #require(try await f.service.check(currentVersion:"0.5.0",runtime:f.runtime))
    let staged = try await f.service.stage(release,currentVersion:"0.5.0",under:root,runtime:f.runtime)
    #expect(try Data(contentsOf:staged.artifact) == f.bytes)
    var info = stat(); #expect(lstat(staged.directory.path,&info) == 0); #expect(info.st_mode & 0o777 == 0o700)
    #expect(lstat(staged.artifact.path,&info) == 0); #expect(info.st_mode & 0o777 == 0o600)
    #expect(UpdateProtocol.seen(f.asset)?.value(forHTTPHeaderField:"Authorization") == nil)
    #expect(UpdateProtocol.seen(f.asset)?.value(forHTTPHeaderField:"Cookie") == nil)
}
@Test func updateSyntheticNetworkRejectsWrongBytesAndRetainsNoCompletedArtifact() async throws {
    let f = UpdateFixture(), root = try f.root(); defer { try? FileManager.default.removeItem(at:root) }
    let release = try #require(try f.service.verify(f.envelope(),currentVersion:"0.5.0",runtime:f.runtime))
    for bytes in [Data(repeating:1,count:f.bytes.count),Data(repeating:1,count:f.bytes.count-1),Data(repeating:1,count:f.bytes.count+1)] {
        UpdateProtocol.add(f.asset,.bytes(bytes))
        await #expect(throws:(any Error).self) { try await f.service.stage(release,currentVersion:"0.5.0",under:root,runtime:f.runtime) }
    }
    let all = try FileManager.default.subpathsOfDirectory(atPath:root.path)
    #expect(!all.contains(where:{$0.hasSuffix(".zip") || $0.hasSuffix(".partial")}))
}
@Test func updateSyntheticRedirectSanitizesHeadersAndRejectsUnapprovedHost() async throws {
    let f = UpdateFixture(), target = URL(string:"https://github.com/Anshmaan29/CloudNest/releases/download/v1.2.3/feed-\(UUID().uuidString).json")!
    UpdateProtocol.add(f.feed,.redirect(target)); UpdateProtocol.add(target,.bytes(try f.envelope()))
    #expect(try await f.service.check(currentVersion:"0.5.0",runtime:f.runtime)?.manifest.version == "1.2.3")
    #expect(UpdateProtocol.seen(target)?.value(forHTTPHeaderField:"Authorization") == nil)
    #expect(UpdateProtocol.seen(target)?.value(forHTTPHeaderField:"Cookie") == nil)
    let other = UpdateFixture(); UpdateProtocol.add(other.feed,.redirect(URL(string:"https://evil.example.invalid/feed")!))
    await #expect(throws:(any Error).self) { try await other.service.check(currentVersion:"0.5.0",runtime:other.runtime) }
}
@Test func updateRefusesSharedOrSymlinkedStagingRootsAndUnsignedApplication() async throws {
    let f = UpdateFixture(), root = try f.root(); defer { try? FileManager.default.removeItem(at:root) }
    let release = try #require(try f.service.verify(f.envelope(),currentVersion:"0.5.0",runtime:f.runtime))
    #expect(chmod(root.path,0o755) == 0)
    await #expect(throws:(any Error).self) { try await f.service.stage(release,currentVersion:"0.5.0",under:root,runtime:f.runtime) }
    #expect(chmod(root.path,0o700) == 0); UpdateProtocol.add(f.asset,.bytes(f.bytes))
    let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
    await #expect(throws:(any Error).self) { try await f.service.stage(release,currentVersion:"0.5.0",under:link,runtime:f.runtime) }
    let staged = try await f.service.stage(release,currentVersion:"0.5.0",under:root,runtime:f.runtime)
    let app = root.appendingPathComponent("CloudNest.app/Contents"); try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
    let info: [String: Any] = ["CFBundleIdentifier":"org.cloudnest.os","CFBundleShortVersionString":"1.2.3","CFBundleVersion":"123","CFBundleExecutable":"CloudNest"]
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Info.plist"))
    await #expect(throws:(any Error).self) { try await f.service.validateApplication(app.deletingLastPathComponent(),staged:staged,currentVersion:"0.5.0") }
}
@Test func updatePublicPublisherConfigurationRejectsInvalidKeysTeamsAndUnexpectedResourceFields() throws {
    let f = UpdateFixture()
    #expect(throws:(any Error).self) { try ReleaseUpdateConfiguration(publicKey:Data(repeating:0,count:31),teamID:"ABC1234567",feedURL:f.feed) }
    #expect(throws:(any Error).self) { try ReleaseUpdateConfiguration(publicKey:f.key.publicKey.rawRepresentation,teamID:"ABC1234567\n",feedURL:f.feed) }
    let root = try f.root(); defer { try? FileManager.default.removeItem(at:root) }
    let bundleURL = root.appendingPathComponent("Publisher.bundle"), resources = bundleURL.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
    try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"invalid.example.publisher","CFBundlePackageType":"BNDL"],format:.xml,options:0).write(to:bundleURL.appendingPathComponent("Contents/Info.plist"))
    var object: [String: Any] = ["schemaVersion":1,"publicKey":f.key.publicKey.rawRepresentation.base64EncodedString(),"teamID":"ABC1234567","feedURL":f.feed.absoluteString]
    let resource = resources.appendingPathComponent("CloudNestReleasePublisher.json")
    try JSONSerialization.data(withJSONObject:object).write(to:resource)
    let bundle = try #require(Bundle(url:bundleURL))
    #expect(try ReleaseUpdateConfiguration.bundled(in:bundle)?.teamID == "ABC1234567")
    object["schemaVersion"] = true; try JSONSerialization.data(withJSONObject:object).write(to:resource)
    #expect(throws:(any Error).self) { try ReleaseUpdateConfiguration.bundled(in:bundle) }
    object["schemaVersion"] = 1; object["privateKey"] = "not-allowed"
    try JSONSerialization.data(withJSONObject:object).write(to:resource)
    #expect(throws:(any Error).self) { try ReleaseUpdateConfiguration.bundled(in:bundle) }
}
