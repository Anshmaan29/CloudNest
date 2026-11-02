import CryptoKit
import Darwin
import Foundation
import Testing

@testable import CloudNestCore

private struct InstallerFixture {
  let root: URL
  let key = Curve25519.Signing.PrivateKey()
  var installed: URL { root.appendingPathComponent("CloudNest.app") }
  var configuration: ReleaseUpdateConfiguration {
    get throws {
      try .init(
        publicKey: key.publicKey.rawRepresentation, teamID: "ABC1234567",
        feedURL: URL(
          string: "https://github.com/Anshmaan29/CloudNest/releases/latest/download/fixture.json")!)
    }
  }
  init() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    root = repo.deletingLastPathComponent().appendingPathComponent(
      "updater-install-" + UUID().uuidString + ".noindex")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Self.writeApp(installed, version: "0.5.0", build: "5")
  }
  static func appFiles(version: String, build: String) throws -> [String: Data] {
    let short = String(version.split(separator: "-", maxSplits: 1)[0])
    let info: [String: Any] = [
      "CFBundleIdentifier": "org.cloudnest.os", "CFBundleExecutable": "CloudNest",
      "CFBundlePackageType": "APPL", "CFBundleShortVersionString": short,
      "CloudNestReleaseVersion": version, "CFBundleVersion": build,
    ]
    return [
      "Contents/Info.plist": try PropertyListSerialization.data(
        fromPropertyList: info, format: .xml, options: 0),
      "Contents/MacOS/CloudNest": Data(("fixture " + version).utf8),
      "Contents/Resources/CloudNest.icns": Data("fixture icon".utf8),
      "Contents/_CodeSignature/CodeResources": Data("fixture signature".utf8),
      "Contents/Helpers/CloudNestUpdateHelper": Data("fixture helper".utf8),
    ]
  }
  static func writeApp(_ url: URL, version: String, build: String) throws {
    for (name, data) in try appFiles(version: version, build: build) {
      let file = url.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
      try data.write(to: file)
      try FileManager.default.setAttributes(
        [.posixPermissions: UpdateArchive.executables.contains(name) ? 0o755 : 0o644],
        ofItemAtPath: file.path)
    }
  }
  static func fakeVerifier(
    _ app: URL, _ config: ReleaseUpdateConfiguration, _ version: String, _ build: String
  ) throws {
    let info = try ReleaseUpdate.applicationMetadata(app)
    guard info.version == version, info.build == build else { throw ReleaseUpdateError.application }
    _ = try UpdateArchive.inventory(app)
  }
  func environment(
    launch: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in },
    candidateRunning: @escaping @Sendable (URL) -> Bool = { _ in false }, wait: Double = 0.05
  ) -> UpdateInstallerEnvironment {
    .init(
      validate: Self.fakeVerifier, oldRunning: { _ in false }, candidateRunning: candidateRunning,
      launch: launch, allowFixtureDestination: true, waitSeconds: wait)
  }
  func staged(version: String = "1.0.0-rc.1", members: [String: Data]? = nil) throws
    -> StagedRelease
  {
    let files = try members ?? Self.appFiles(version: version, build: "10001")
    let zip = storedZip(files)
    let directory = root.appendingPathComponent("download")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let artifact = directory.appendingPathComponent("CloudNest.zip")
    try zip.write(to: artifact)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.path)
    let formatter = ISO8601DateFormatter()
    let raw: [String: Any] = [
      "schemaVersion": 1, "version": version, "build": "10001", "minimumMacOS": "14.0",
      "architectures": ["arm64", "x86_64"],
      "assetURL": "https://github.com/Anshmaan29/CloudNest/releases/download/fixture/CloudNest.zip",
      "bytes": zip.count, "sha256": Self.hash(zip),
      "publishedAt": formatter.string(from: Date().addingTimeInterval(-60)),
      "expiresAt": formatter.string(from: Date().addingTimeInterval(3600)),
    ]
    let payload = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    let envelope = try JSONSerialization.data(withJSONObject: [
      "payload": payload.base64EncodedString(),
      "signature": try key.signature(for: payload).base64EncodedString(),
    ])
    let release = try #require(
      try ReleaseUpdate(configuration: configuration).verify(envelope, currentVersion: "0.5.0"))
    return .init(directory: directory, artifact: artifact, release: release)
  }
  func prepare(_ staged: StagedRelease, environment: UpdateInstallerEnvironment? = nil) throws
    -> PreparedUpdateInstallation
  {
    try ReleaseUpdateInstaller.prepare(
      staged: staged, configuration: configuration, currentApp: installed, oldProcess: .capture(),
      environment: environment ?? self.environment())
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
private func storedZip(_ files: [String: Data], modeOverride: [String: UInt32] = [:]) -> Data {
  var local = Data()
  var central = Data()
  let prefix = "CloudNest.app/"
  for name in files.keys.sorted() {
    let bytes = files[name]!
    let path = Data((prefix + name).utf8)
    let offset = local.count
    let crc = zipCRC(bytes)
    let mode =
      modeOverride[name] ?? (UpdateArchive.executables.contains(name) ? 0o100755 : 0o100644)
    var h = Data(repeating: 0, count: 30)
    h.put32(0x0403_4b50, 0)
    h.put16(20, 4)
    h.put16(0x800, 6)
    h.put32(crc, 14)
    h.put32(UInt32(bytes.count), 18)
    h.put32(UInt32(bytes.count), 22)
    h.put16(UInt16(path.count), 26)
    local.append(h)
    local.append(path)
    local.append(bytes)
    var c = Data(repeating: 0, count: 46)
    c.put32(0x0201_4b50, 0)
    c.put16(0x314, 4)
    c.put16(20, 6)
    c.put16(0x800, 8)
    c.put32(crc, 16)
    c.put32(UInt32(bytes.count), 20)
    c.put32(UInt32(bytes.count), 24)
    c.put16(UInt16(path.count), 28)
    c.put32(mode << 16, 38)
    c.put32(UInt32(offset), 42)
    central.append(c)
    central.append(path)
  }
  var e = Data(repeating: 0, count: 22)
  e.put32(0x0605_4b50, 0)
  e.put16(UInt16(files.count), 8)
  e.put16(UInt16(files.count), 10)
  e.put32(UInt32(central.count), 12)
  e.put32(UInt32(local.count), 16)
  local.append(central)
  local.append(e)
  return local
}
extension Data {
  fileprivate mutating func put16(_ value: UInt16, _ at: Int) {
    self[at] = UInt8(truncatingIfNeeded: value)
    self[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
  }
  fileprivate mutating func put32(_ value: UInt32, _ at: Int) {
    put16(UInt16(truncatingIfNeeded: value), at)
    put16(UInt16(truncatingIfNeeded: value >> 16), at + 2)
  }
}
private func zipCRC(_ data: Data) -> UInt32 {
  var crc = UInt32.max
  for byte in data {
    crc ^= UInt32(byte)
    for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
  }
  return ~crc
}

@Test func updateExtractionBindsExactSignedZipAndRCMetadataWithoutBundleCache() throws {
  let f = try InstallerFixture()
  defer { f.clean() }
  let prepared = try f.prepare(f.staged())
  let plan: UpdateInstallPlan = try ReleaseUpdateInstaller.read(prepared.planURL, maximum: 131072)
  #expect(plan.oldDigest != plan.newDigest)
  #expect(try UpdateArchive.inventory(f.installed) == plan.oldDigest)
  #expect(
    try ReleaseUpdate.applicationMetadata(
      prepared.directory.appendingPathComponent("CloudNest.app")
    ).version == "1.0.0-rc.1")
  #expect(try ReleaseUpdate.applicationMetadata(f.installed).version == "0.5.0")
}
@Test func updateExtractionRejectsTraversalExtraPrivateFilesSymlinksAndMutatedArtifact() throws {
  for name in [
    "../escape", "Contents/Resources/owner-token.private.txt", "Contents/Resources/unknown.json",
  ] {
    let f = try InstallerFixture()
    defer { f.clean() }
    var files = try InstallerFixture.appFiles(version: "1.0.0", build: "10001")
    files[name] = Data("fixture".utf8)
    #expect(throws: (any Error).self) { try f.prepare(f.staged(version: "1.0.0", members: files)) }
    #expect(try ReleaseUpdate.applicationMetadata(f.installed).version == "0.5.0")
  }
  let f = try InstallerFixture()
  defer { f.clean() }
  let staged = try f.staged()
  try Data("changed".utf8).write(to: staged.artifact)
  #expect(throws: (any Error).self) { try f.prepare(staged) }
  let files = try InstallerFixture.appFiles(version: "1.0.0", build: "10001")
  let zip = storedZip(files, modeOverride: ["Contents/MacOS/CloudNest": 0o120777])
  let file = f.root.appendingPathComponent("linked.zip")
  try zip.write(to: file)
  let handle = try FileHandle(forReadingFrom: file)
  defer { try? handle.close() }
  #expect(throws: (any Error).self) { try UpdateArchive.members(handle, size: Int64(zip.count)) }
}
@Test func updateInstallAcknowledgmentKeepsVerifiedPreviousApplication() async throws {
  let f = try InstallerFixture()
  defer { f.clean() }
  let staged = try f.staged()
  let prepared = try f.prepare(staged)
  let env = f.environment(launch: { app, request in
    let plan: UpdateInstallPlan = try ReleaseUpdateInstaller.read(request, maximum: 131072)
    let caller = try UpdateProcessIdentity.capture()
    let simulated = UpdateProcessIdentity(
      pid: caller.pid, startedSeconds: caller.startedSeconds,
      startedMicroseconds: caller.startedMicroseconds,
      executable: app.appendingPathComponent("Contents/MacOS/CloudNest").path, uid: getuid())
    try ReleaseUpdateInstaller.write(
      UpdateLaunchAcknowledgment(
        schemaVersion: 1, id: plan.id, challenge: plan.challenge, process: simulated,
        digest: plan.newDigest), name: "ack.json", directory: request.deletingLastPathComponent(),
      exclusive: true)
  })
  try await ReleaseUpdateInstaller.execute(
    planURL: prepared.planURL, configuration: f.configuration, environment: env)
  let state: UpdateInstallState = try ReleaseUpdateInstaller.read(
    prepared.directory.appendingPathComponent("state.json"), maximum: 8192)
  #expect(state.phase == "installed")
  #expect(try ReleaseUpdate.applicationMetadata(f.installed).version == "1.0.0-rc.1")
  #expect(
    try ReleaseUpdate.applicationMetadata(
      prepared.directory.appendingPathComponent("CloudNest.app")
    ).version == "0.5.0")
}
@Test func failedUpdateLaunchRestoresPreviousAppWithoutTouchingUserData() async throws {
  let f = try InstallerFixture()
  defer { f.clean() }
  let marker = f.root.appendingPathComponent("user-data.txt")
  try Data("preserve".utf8).write(to: marker)
  let prepared = try f.prepare(f.staged())
  let oldDigest = try UpdateArchive.inventory(f.installed)
  await #expect(throws: (any Error).self) {
    try await ReleaseUpdateInstaller.execute(
      planURL: prepared.planURL, configuration: f.configuration,
      environment: f.environment(launch: { _, _ in throw ReleaseUpdateError.application }))
  }
  #expect(try UpdateArchive.inventory(f.installed) == oldDigest)
  #expect(try String(contentsOf: marker, encoding: .utf8) == "preserve")
  let state: UpdateInstallState = try ReleaseUpdateInstaller.read(
    prepared.directory.appendingPathComponent("state.json"), maximum: 8192)
  #expect(state.phase == "rolledBack")
}
@Test func unacknowledgedRunningUpdateIsRetainedForExplicitRecovery() async throws {
  let f = try InstallerFixture()
  defer { f.clean() }
  let prepared = try f.prepare(f.staged())
  let env = f.environment(
    launch: { _, _ in },
    candidateRunning: { app in (try? ReleaseUpdate.applicationMetadata(app).version) == "1.0.0-rc.1"
    })
  await #expect(throws: (any Error).self) {
    try await ReleaseUpdateInstaller.execute(
      planURL: prepared.planURL, configuration: f.configuration, environment: env)
  }
  let state: UpdateInstallState = try ReleaseUpdateInstaller.read(
    prepared.directory.appendingPathComponent("state.json"), maximum: 8192)
  #expect(state.phase == "needsRecovery")
  #expect(try ReleaseUpdate.applicationMetadata(f.installed).version == "1.0.0-rc.1")
  let recoveries = try ReleaseUpdateInstaller.recoveries(currentApp: f.installed, fixture: true)
  #expect(recoveries.first?.canRollback == true)
}
@Test func updateRejectsChangedOldAppAndWrongAcknowledgment() async throws {
  let f = try InstallerFixture()
  defer { f.clean() }
  let prepared = try f.prepare(f.staged())
  try Data("tampered".utf8).write(
    to: f.installed.appendingPathComponent("Contents/MacOS/CloudNest"))
  await #expect(throws: (any Error).self) {
    try await ReleaseUpdateInstaller.execute(
      planURL: prepared.planURL, configuration: f.configuration, environment: f.environment())
  }
  #expect(
    try String(
      contentsOf: f.installed.appendingPathComponent("Contents/MacOS/CloudNest"), encoding: .utf8)
      == "tampered")
}
@Test func updateProcessIdentityRejectsPIDReuseOrWrongStartToken() throws {
  let current = try UpdateProcessIdentity.capture()
  #expect(current.isStillRunning)
  let altered = UpdateProcessIdentity(
    pid: current.pid, startedSeconds: current.startedSeconds + 1,
    startedMicroseconds: current.startedMicroseconds, executable: current.executable,
    uid: current.uid)
  #expect(!altered.isStillRunning)
}

@Test func helperProcessIdentitySurvivesItsExecutableMovingIntoBackup() throws {
  let current = try UpdateProcessIdentity.capture()
  let renamed = UpdateProcessIdentity(
    pid: current.pid, startedSeconds: current.startedSeconds,
    startedMicroseconds: current.startedMicroseconds,
    executable: "/synthetic-backup/CloudNestUpdateHelper", uid: current.uid)
  #expect(renamed.isStillRunning)
}
@Test func corruptAcknowledgmentRollsBackInsteadOfReportingSuccess() async throws {
  let f = try InstallerFixture()
  defer { f.clean() }
  let prepared = try f.prepare(f.staged())
  let env = f.environment(launch: { app, request in
    let plan: UpdateInstallPlan = try ReleaseUpdateInstaller.read(request, maximum: 131072)
    let caller = try UpdateProcessIdentity.capture()
    let identity = UpdateProcessIdentity(
      pid: caller.pid, startedSeconds: caller.startedSeconds,
      startedMicroseconds: caller.startedMicroseconds,
      executable: app.appendingPathComponent("Contents/MacOS/CloudNest").path, uid: getuid())
    try ReleaseUpdateInstaller.write(
      UpdateLaunchAcknowledgment(
        schemaVersion: 1, id: plan.id, challenge: String(repeating: "0", count: 64),
        process: identity, digest: plan.newDigest), name: "ack.json",
      directory: request.deletingLastPathComponent(), exclusive: true)
  })
  await #expect(throws: (any Error).self) {
    try await ReleaseUpdateInstaller.execute(
      planURL: prepared.planURL, configuration: f.configuration, environment: env)
  }
  #expect(try ReleaseUpdate.applicationMetadata(f.installed).version == "0.5.0")
  let state: UpdateInstallState = try ReleaseUpdateInstaller.read(
    prepared.directory.appendingPathComponent("state.json"), maximum: 8192)
  #expect(state.phase == "rolledBack")
}
@Test func crashAfterExchangeOffersAndPerformsVerifiedExplicitRollback() async throws {
  let f = try InstallerFixture()
  defer { f.clean() }
  let prepared = try f.prepare(f.staged())
  let plan: UpdateInstallPlan = try ReleaseUpdateInstaller.read(prepared.planURL, maximum: 131072)
  try ReleaseUpdateInstaller.exchange(
    target: f.installed, other: prepared.directory.appendingPathComponent("CloudNest.app"))
  try ReleaseUpdateInstaller.state(plan, "swapping", directory: prepared.directory, helper: nil)
  let recoveries = try ReleaseUpdateInstaller.recoveries(currentApp: f.installed, fixture: true)
  #expect(recoveries.first?.canRollback == true)
  let current = try UpdateProcessIdentity.capture()
  let identity = UpdateProcessIdentity(
    pid: current.pid, startedSeconds: current.startedSeconds,
    startedMicroseconds: current.startedMicroseconds,
    executable: f.installed.appendingPathComponent("Contents/MacOS/CloudNest").path, uid: getuid())
  try ReleaseUpdateInstaller.write(
    UpdateLaunchAcknowledgment(
      schemaVersion: 1, id: plan.id, challenge: plan.challenge, process: identity,
      digest: plan.newDigest), name: "rollback.json", directory: prepared.directory, exclusive: true
  )
  try await ReleaseUpdateInstaller.rollback(
    planURL: prepared.planURL, configuration: f.configuration, environment: f.environment())
  #expect(try UpdateArchive.inventory(f.installed) == plan.oldDigest)
  #expect(
    try UpdateArchive.inventory(prepared.directory.appendingPathComponent("CloudNest.app"))
      == plan.newDigest)
}
@Test func updaterGlobalLeaseExcludesDifferentTransactionsForSameInstallation() throws {
  let f = try InstallerFixture()
  defer { f.clean() }
  let lease = try ReleaseUpdateInstaller.globalLease(target: f.installed)
  #expect(throws: (any Error).self) { try ReleaseUpdateInstaller.globalLease(target: f.installed) }
  withExtendedLifetime(lease) {}
}
