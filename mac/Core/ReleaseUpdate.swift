import CryptoKit
import Darwin
import Foundation
import Security

public enum ReleaseUpdateError: Error, LocalizedError {
  case configuration, manifest, signature, incompatible, redirect, network, integrity, unsafeStage,
    application, installLocation
  public var errorDescription: String? {
    switch self {
    case .configuration:
      "Signed updates are unavailable: a reviewed publisher public key, Developer ID Team ID and release feed must be bundled first."
    case .manifest: "The update manifest is invalid, expired or outside the supported limits."
    case .signature: "The publisher signature did not verify. No update can be trusted."
    case .incompatible:
      "This release does not support this Mac or is not newer than the installed version."
    case .redirect:
      "The release redirected outside the approved GitHub delivery chain or exceeded its redirect budget."
    case .network:
      "The release request failed. No credentials were sent and no automatic retry was made."
    case .integrity: "The downloaded release does not match its signed size and SHA-256."
    case .unsafeStage: "The private update staging location is unavailable or has changed."
    case .installLocation:
      "Move CloudNest into a writable, user-owned /Applications or ~/Applications installation before updating. No administrator access is requested."
    case .application:
      "Application validation failed. A matching Developer ID, version, build and notarized Gatekeeper assessment are required."
    }
  }
}
public struct ReleaseVersion: Comparable, Sendable {
  public let text: String
  private let numbers: [Int]
  private let prerelease: [String]
  public init(_ text: String) throws {
    guard text.utf8.count <= 128,
      text.range(
        of:
          "^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?\\z",
        options: .regularExpression) != nil
    else { throw ReleaseUpdateError.manifest }
    self.text = text
    let core = text.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)
    numbers = core[0].split(separator: ".").compactMap { Int($0) }
    prerelease = core.count == 2 ? core[1].split(separator: ".").map(String.init) : []
    guard prerelease.allSatisfy({ !$0.allSatisfy(\.isNumber) || $0.count == 1 || $0.first != "0" })
    else { throw ReleaseUpdateError.manifest }
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
  }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
    if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
      return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
    }
    for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
      let an = a.allSatisfy(\.isNumber)
      let bn = b.allSatisfy(\.isNumber)
      if an != bn { return an }
      if an && a.count != b.count { return a.count < b.count }
      return a < b
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }
}
public struct ReleaseUpdateConfiguration: Sendable {
  public let publicKey: Data
  public let teamID: String
  public let feedURL: URL
  public init(publicKey: Data, teamID: String, feedURL: URL) throws {
    guard publicKey.count == 32,
      teamID.range(of: "^[A-Z0-9]{10}\\z", options: .regularExpression) != nil,
      ReleaseRedirectPolicy.isRepositoryAsset(feedURL)
    else { throw ReleaseUpdateError.configuration }
    _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    self.publicKey = publicKey
    self.teamID = teamID
    self.feedURL = feedURL
  }
  public static func bundled(in bundle: Bundle = .main) throws -> Self? {
    guard let url = bundle.url(forResource: "CloudNestReleasePublisher", withExtension: "json")
    else { return nil }
    return try decode(boundedFile(url, maximum: 4096))
  }
  static func atApplication(_ app: URL) throws -> Self? {
    let url = app.appendingPathComponent("Contents/Resources/CloudNestReleasePublisher.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try decode(boundedFile(url, maximum: 4096))
  }
  private static func decode(_ data: Data) throws -> Self {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["schemaVersion", "publicKey", "teamID", "feedURL"]),
      object["schemaVersion"] as? Int == 1,
      CFGetTypeID(object["schemaVersion"] as CFTypeRef) != CFBooleanGetTypeID(),
      let key = object["publicKey"] as? String, let bytes = Data(base64Encoded: key),
      bytes.base64EncodedString() == key,
      let team = object["teamID"] as? String, let feed = object["feedURL"] as? String,
      let feedURL = URL(string: feed)
    else { throw ReleaseUpdateError.configuration }
    return try Self(publicKey: bytes, teamID: team, feedURL: feedURL)
  }
}
public struct ReleaseUpdateRuntime: Sendable {
  public let architecture: String
  public let macOS: OperatingSystemVersion
  public init(architecture: String, macOS: OperatingSystemVersion) {
    self.architecture = architecture
    self.macOS = macOS
  }
  public static var current: Self {
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    return Self(architecture: architecture, macOS: ProcessInfo.processInfo.operatingSystemVersion)
  }
}
public struct ReleaseManifest: Decodable, Sendable {
  public let schemaVersion: Int
  public let version: String
  public let build: String
  public let minimumMacOS: String
  public let architectures: [String]
  public let assetURL: URL
  public let bytes: Int64
  public let sha256: String
  public let publishedAt: Date
  public let expiresAt: Date
}
public struct VerifiedRelease: Sendable {
  public let manifest: ReleaseManifest
  let signedEnvelope: Data
}
public struct StagedRelease: Sendable {
  public let directory: URL
  public let artifact: URL
  public let release: VerifiedRelease
}
/// Redirect URLs and signed CDN query parameters are never included in diagnostics.
public struct ReleaseRedirectPolicy: Sendable {
  public private(set) var hops = 0
  private var seen: Set<URL>
  public init(initial: URL) throws {
    guard Self.isRepositoryAsset(initial) else { throw ReleaseUpdateError.redirect }
    seen = [initial]
  }
  private static func safe(_ url: URL) -> Bool {
    url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
      && url.fragment == nil && url.absoluteString.utf8.count <= 8192
  }
  public static func isRepositoryAsset(_ url: URL) -> Bool {
    guard safe(url), url.host == "github.com", url.query == nil else { return false }
    return !url.pathComponents.contains(where: { $0 == "." || $0 == ".." })
      && url.path.range(
        of:
          "^/Anshmaan29/CloudNest/releases/(latest/download/[A-Za-z0-9._-]+|download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)\\z",
        options: .regularExpression) != nil
      && !url.absoluteString.contains("%")
  }
  public static func isReleaseCDN(_ url: URL) -> Bool {
    safe(url) && url.host == "release-assets.githubusercontent.com"
      && url.path.range(
        of: "^/github-production-release-asset/[0-9]+/[A-Fa-f0-9-]{36}\\z",
        options: .regularExpression) != nil
  }
  public mutating func accept(from: URL, to: URL) throws {
    guard hops < 3, seen.contains(from), Self.isRepositoryAsset(from),
      Self.isRepositoryAsset(to) || Self.isReleaseCDN(to), !seen.contains(to)
    else { throw ReleaseUpdateError.redirect }
    hops += 1
    seen.insert(to)
  }
}
public struct ReleaseUpdate: Sendable {
  public let configuration: ReleaseUpdateConfiguration
  private let transport: ReleaseTransport
  public init(configuration: ReleaseUpdateConfiguration) {
    self.configuration = configuration
    transport = ReleaseTransport()
  }
  init(configuration: ReleaseUpdateConfiguration, sessionConfiguration: URLSessionConfiguration) {
    self.configuration = configuration
    transport = ReleaseTransport(configuration: sessionConfiguration)
  }
  public static func installedVersion(in bundle: Bundle = .main) -> String {
    bundle.object(forInfoDictionaryKey: "CloudNestReleaseVersion") as? String ?? bundle.object(
      forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }
  struct ApplicationMetadata {
    let version: String
    let build: String
  }
  static func applicationMetadata(_ app: URL) throws -> ApplicationMetadata {
    let data = try boundedFile(app.appendingPathComponent("Contents/Info.plist"), maximum: 65536)
    guard
      let info = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any], info["CFBundleIdentifier"] as? String == "org.cloudnest.os",
      let short = info["CFBundleShortVersionString"] as? String,
      let build = info["CFBundleVersion"] as? String
    else { throw ReleaseUpdateError.application }
    let version = info["CloudNestReleaseVersion"] as? String ?? short
    _ = try ReleaseVersion(version)
    guard
      short
        == String(
          version.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)[0]),
      build.range(of: "^[0-9]{1,12}\\z", options: .regularExpression) != nil
    else { throw ReleaseUpdateError.application }
    return ApplicationMetadata(version: version, build: build)
  }
  public func check(currentVersion: String, runtime: ReleaseUpdateRuntime = .current) async throws
    -> VerifiedRelease?
  {
    let result = try await transport.fetch(configuration.feedURL, maximum: 65536, destination: nil)
    return try verify(result.data, currentVersion: currentVersion, runtime: runtime)
  }
  public func verify(
    _ data: Data, currentVersion: String, runtime: ReleaseUpdateRuntime = .current,
    now: Date = Date()
  ) throws -> VerifiedRelease? {
    guard data.count <= 65536,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == Set(["payload", "signature"]),
      let encoded = object["payload"] as? String, let payload = Data(base64Encoded: encoded),
      payload.count <= 32768, payload.base64EncodedString() == encoded,
      let signatureText = object["signature"] as? String,
      let signature = Data(base64Encoded: signatureText), signature.count == 64,
      signature.base64EncodedString() == signatureText
    else { throw ReleaseUpdateError.manifest }
    guard
      try Curve25519.Signing.PublicKey(rawRepresentation: configuration.publicKey).isValidSignature(
        signature, for: payload)
    else { throw ReleaseUpdateError.signature }
    let keys = [
      "schemaVersion", "version", "build", "minimumMacOS", "architectures", "assetURL", "bytes",
      "sha256", "publishedAt", "expiresAt",
    ]
    guard let raw = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
      Set(raw.keys) == Set(keys)
    else { throw ReleaseUpdateError.manifest }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(ReleaseManifest.self, from: payload)
    guard manifest.schemaVersion == 1, manifest.bytes > 0, manifest.bytes <= 209_715_200,
      manifest.build.range(of: "^[0-9]{1,12}\\z", options: .regularExpression) != nil,
      manifest.sha256.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil,
      ReleaseRedirectPolicy.isRepositoryAsset(manifest.assetURL),
      ["zip", "dmg"].contains(manifest.assetURL.pathExtension),
      (1...2).contains(manifest.architectures.count),
      Set(manifest.architectures).count == manifest.architectures.count,
      manifest.architectures.allSatisfy({ ["arm64", "x86_64"].contains($0) }),
      manifest.publishedAt <= now.addingTimeInterval(300), manifest.expiresAt > now,
      manifest.expiresAt > manifest.publishedAt,
      manifest.expiresAt.timeIntervalSince(manifest.publishedAt) <= 90 * 86400
    else { throw ReleaseUpdateError.manifest }
    let minimum = try Self.operatingSystem(manifest.minimumMacOS)
    guard manifest.architectures.contains(runtime.architecture),
      Self.atLeast(runtime.macOS, minimum)
    else { throw ReleaseUpdateError.incompatible }
    let candidate = try ReleaseVersion(manifest.version)
    let installed = try ReleaseVersion(currentVersion)
    guard candidate > installed else { return nil }
    return VerifiedRelease(manifest: manifest, signedEnvelope: data)
  }
  public static func defaultStagingDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    var descriptor = try FileSafety.openDirectory(support)
    defer { close(descriptor) }
    var url = support
    for name in ["CloudNest", "Updates"] {
      if mkdirat(descriptor, name, 0o700) != 0 && errno != EEXIST {
        throw ReleaseUpdateError.unsafeStage
      }
      let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw ReleaseUpdateError.unsafeStage }
      close(descriptor)
      descriptor = next
      url.appendPathComponent(name)
      let checked = try privateDirectory(url)
      close(checked)
    }
    return url
  }
  public func stage(
    _ release: VerifiedRelease, currentVersion: String, under root: URL,
    runtime: ReleaseUpdateRuntime = .current
  ) async throws -> StagedRelease {
    guard
      let verified = try verify(
        release.signedEnvelope, currentVersion: currentVersion, runtime: runtime)
    else { throw ReleaseUpdateError.incompatible }
    let parent = try Self.privateDirectory(root)
    defer { close(parent) }
    let name = UUID().uuidString
    guard mkdirat(parent, name, 0o700) == 0 else { throw ReleaseUpdateError.unsafeStage }
    let directory = root.appendingPathComponent(name)
    let job = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard job >= 0 else { throw ReleaseUpdateError.unsafeStage }
    defer { close(job) }
    let descriptor = openat(
      job, "download.partial", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw ReleaseUpdateError.unsafeStage }
    var original = stat()
    guard fstat(descriptor, &original) == 0 else {
      close(descriptor)
      throw ReleaseUpdateError.unsafeStage
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      let result = try await transport.fetch(
        verified.manifest.assetURL, maximum: verified.manifest.bytes, destination: handle)
      guard result.bytes == verified.manifest.bytes, result.sha256 == verified.manifest.sha256
      else { throw ReleaseUpdateError.integrity }
      try handle.synchronize()
      try handle.seek(toOffset: 0)
      let snapshot = try FileSafety.snapshot(handle)
      var named = stat()
      guard snapshot.sha256 == verified.manifest.sha256,
        snapshot.identity.size == verified.manifest.bytes,
        fstatat(job, "download.partial", &named, AT_SYMLINK_NOFOLLOW) == 0,
        FileSafety.identity(named) == snapshot.identity, named.st_nlink == 1
      else { throw ReleaseUpdateError.integrity }
      let artifactName =
        "CloudNest-" + verified.manifest.version + "." + verified.manifest.assetURL.pathExtension
      guard renameatx_np(job, "download.partial", job, artifactName, UInt32(RENAME_EXCL)) == 0,
        fstatat(job, artifactName, &named, AT_SYMLINK_NOFOLLOW) == 0,
        FileSafety.identity(named).device == snapshot.identity.device,
        FileSafety.identity(named).inode == snapshot.identity.inode, fsync(job) == 0
      else { throw ReleaseUpdateError.unsafeStage }
      try handle.close()
      let envelope = openat(
        job, "release.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard envelope >= 0 else { throw ReleaseUpdateError.unsafeStage }
      let record = FileHandle(fileDescriptor: envelope, closeOnDealloc: true)
      try record.write(contentsOf: verified.signedEnvelope)
      try record.synchronize()
      try record.close()
      guard fsync(job) == 0, fsync(parent) == 0 else { throw ReleaseUpdateError.unsafeStage }
      return StagedRelease(
        directory: directory, artifact: directory.appendingPathComponent(artifactName),
        release: verified)
    } catch {
      try? handle.close()
      var remaining = stat()
      if fstatat(job, "download.partial", &remaining, AT_SYMLINK_NOFOLLOW) == 0,
        remaining.st_dev == original.st_dev, remaining.st_ino == original.st_ino
      {
        _ = unlinkat(job, "download.partial", 0)
      }
      // Never recursively remove a changed or unknown staging directory.
      throw error
    }
  }
  /// No app replacement or execution occurs. A user-selected extracted app must
  /// independently match the signed release and Apple's current trust policy.
  public func validateApplication(_ app: URL, staged: StagedRelease, currentVersion: String)
    async throws
  {
    guard let verified = try verify(staged.release.signedEnvelope, currentVersion: currentVersion)
    else { throw ReleaseUpdateError.incompatible }
    let stage = try Self.privateDirectory(staged.directory)
    defer { close(stage) }
    let bytes = try FileSafety.openDirectory(app)
    defer { close(bytes) }
    guard !app.path.utf8.contains(where: { $0 < 32 || $0 == 127 }), app.pathExtension == "app",
      try Self.applicationMetadata(app).version == verified.manifest.version,
      try Self.applicationMetadata(app).build == verified.manifest.build
    else { throw ReleaseUpdateError.application }
    let artifact = openat(
      stage, staged.artifact.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard artifact >= 0 else { throw ReleaseUpdateError.unsafeStage }
    defer { close(artifact) }
    var info = stat()
    guard fstat(artifact, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size == verified.manifest.bytes
    else { throw ReleaseUpdateError.integrity }
    let handle = FileHandle(fileDescriptor: artifact, closeOnDealloc: false)
    var hash = SHA256()
    var count: Int64 = 0
    while let data = try autoreleasepool(invoking: { try handle.read(upToCount: 1_048_576) }),
      !data.isEmpty
    {
      try Task.checkCancellation()
      hash.update(data: data)
      count += Int64(data.count)
      guard count <= verified.manifest.bytes else { throw ReleaseUpdateError.integrity }
    }
    guard count == verified.manifest.bytes, Self.hex(hash.finalize()) == verified.manifest.sha256
    else { throw ReleaseUpdateError.integrity }
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let rule =
      "anchor apple generic and certificate leaf[subject.OU] = \"\(configuration.teamID)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"org.cloudnest.os\""
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
      SecStaticCodeCheckValidity(
        code,
        SecCSFlags(
          rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode),
        requirement)
        == errSecSuccess
    else { throw ReleaseUpdateError.application }
    try Self.notarized(app)
  }
  private static func operatingSystem(_ value: String) throws -> OperatingSystemVersion {
    guard
      value.range(
        of: "^[1-9][0-9]{0,2}\\.(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2}))?\\z",
        options: .regularExpression) != nil
    else { throw ReleaseUpdateError.manifest }
    let parts = value.split(separator: ".").compactMap { Int($0) }
    return OperatingSystemVersion(
      majorVersion: parts[0], minorVersion: parts[1], patchVersion: parts.count == 3 ? parts[2] : 0)
  }
  private static func atLeast(_ a: OperatingSystemVersion, _ b: OperatingSystemVersion) -> Bool {
    [a.majorVersion, a.minorVersion, a.patchVersion].lexicographicallyPrecedes([
      b.majorVersion, b.minorVersion, b.patchVersion,
    ]) == false
  }
  static func privateDirectory(_ url: URL) throws -> Int32 {
    let fd = try FileSafety.openDirectory(url)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
      close(fd)
      throw ReleaseUpdateError.unsafeStage
    }
    guard let security = filesec_init() else {
      close(fd)
      throw ReleaseUpdateError.unsafeStage
    }
    defer { filesec_free(security) }
    var secured = stat()
    var acl: Int32 = 0
    guard fstatx_np(fd, &secured, security) == 0, secured.st_ino == info.st_ino,
      secured.st_dev == info.st_dev,
      filesec_query_property(security, FILESEC_ACL, &acl) == 0, acl == 0
    else {
      close(fd)
      throw ReleaseUpdateError.unsafeStage
    }
    return fd
  }
  fileprivate static func hex<T: Sequence>(_ data: T) -> String where T.Element == UInt8 {
    data.map { String(format: "%02x", $0) }.joined()
  }
  static func notarized(_ app: URL) throws {
    let process = Process()
    let pipe = Pipe()
    let ended = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
    process.arguments = ["--assess", "--type", "execute", "--verbose=4", app.path]
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin", "LANG": "C", "LC_ALL": "C"]
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    process.terminationHandler = { _ in ended.signal() }
    try process.run()
    try? pipe.fileHandleForWriting.close()
    defer { try? pipe.fileHandleForReading.close() }
    let fd = pipe.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    do {
      while process.isRunning {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          throw ReleaseUpdateError.application
        }
        let count = read(fd, &buffer, buffer.count)
        if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
        guard output.count <= 16384 else { throw ReleaseUpdateError.application }
        _ = ended.wait(timeout: .now() + .milliseconds(10))
      }
      while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        output.append(contentsOf: buffer.prefix(count))
        guard output.count <= 16384 else { throw ReleaseUpdateError.application }
      }
      guard process.terminationReason == .exit, process.terminationStatus == 0,
        String(decoding: output, as: UTF8.self).split(separator: "\n").contains(
          "source=Notarized Developer ID")
      else { throw ReleaseUpdateError.application }
    } catch {
      if process.isRunning {
        process.terminate()
        if ended.wait(timeout: .now() + 1) == .timedOut {
          _ = kill(process.processIdentifier, SIGKILL)
        }
      }
      throw ReleaseUpdateError.application
    }
  }
}
func boundedFile(_ url: URL, maximum: Int) throws -> Data {
  let parent = try FileSafety.openDirectory(url.deletingLastPathComponent())
  defer { close(parent) }
  let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard fd >= 0 else { throw ReleaseUpdateError.configuration }
  defer { close(fd) }
  var info = stat()
  guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
    info.st_size <= maximum
  else { throw ReleaseUpdateError.configuration }
  let data =
    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1) ?? Data()
  guard data.count == info.st_size else { throw ReleaseUpdateError.configuration }
  return data
}
private struct ReleaseTransfer: Sendable {
  let data: Data
  let bytes: Int64
  let sha256: String
}
private struct ReleaseTransport: @unchecked Sendable {
  let configuration: URLSessionConfiguration
  init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }
  func fetch(_ url: URL, maximum: Int64, destination: FileHandle?) async throws -> ReleaseTransfer {
    let cancellation = DownloadCancellation()
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = destination == nil ? 30 : 600
    return try await withTaskCancellationHandler(
      operation: {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          do {
            let receiver = try ReleaseReceiver(
              initial: url, maximum: maximum, destination: destination
            ) { continuation.resume(with: $0) }
            let session = URLSession(
              configuration: configuration, delegate: receiver, delegateQueue: nil)
            let task = session.dataTask(with: ReleaseReceiver.request(url))
            cancellation.register(task)
            task.resume()
          } catch { continuation.resume(throwing: error) }
        }
      }, onCancel: { cancellation.cancel() })
  }
}
private final class ReleaseReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  var policy: ReleaseRedirectPolicy
  let maximum: Int64, destination: FileHandle?,
    completion: @Sendable (Result<ReleaseTransfer, any Error>) -> Void
  var failure: (any Error)?, data = Data(), count: Int64 = 0, digest = SHA256()
  init(
    initial: URL, maximum: Int64, destination: FileHandle?,
    completion: @escaping @Sendable (Result<ReleaseTransfer, any Error>) -> Void
  ) throws {
    policy = try ReleaseRedirectPolicy(initial: initial)
    self.maximum = maximum
    self.destination = destination
    self.completion = completion
  }
  static func request(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("CloudNest-Update", forHTTPHeaderField: "User-Agent")
    return request
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    do {
      guard let from = response.url, let target = request.url else {
        throw ReleaseUpdateError.redirect
      }
      try policy.accept(from: from, to: target)
      completionHandler(Self.request(target))
    } catch {
      failure = ReleaseUpdateError.redirect
      completionHandler(nil)
      task.cancel()
    }
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.expectedContentLength <= maximum,
      response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true
    else {
      failure = ReleaseUpdateError.network
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    do {
      guard Int64(chunk.count) <= maximum - count else { throw ReleaseUpdateError.integrity }
      count += Int64(chunk.count)
      digest.update(data: chunk)
      if let destination {
        try autoreleasepool { try destination.write(contentsOf: chunk) }
      } else {
        data.append(chunk)
      }
    } catch {
      failure = error
      dataTask.cancel()
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    defer { session.finishTasksAndInvalidate() }
    if let failure = failure {
      completion(.failure(failure))
    } else if error != nil {
      completion(.failure(ReleaseUpdateError.network))
    } else {
      completion(
        .success(
          ReleaseTransfer(data: data, bytes: count, sha256: ReleaseUpdate.hex(digest.finalize()))))
    }
  }
}
