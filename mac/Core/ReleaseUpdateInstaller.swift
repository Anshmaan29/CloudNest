import CryptoKit
import Darwin
import Foundation
import Security

public struct UpdateProcessIdentity: Codable, Equatable, Sendable {
  public let pid: Int32
  public let startedSeconds: UInt64
  public let startedMicroseconds: UInt64
  public let executable: String
  public let uid: UInt32
  public static func capture(_ pid: Int32 = getpid()) throws -> Self {
    var info = proc_bsdinfo()
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        == MemoryLayout<proc_bsdinfo>.size,
      proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
    else { throw ReleaseUpdateError.application }
    return Self(
      pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec,
      executable: String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
      uid: info.pbi_uid)
  }
  public var isStillRunning: Bool {
    guard let current = try? Self.capture(pid) else { return false }
    // A running helper's executable moves into the backup during exchange.
    // PID, owner and kernel start token remain stable; its path does not.
    return current.pid == pid && current.uid == uid && current.startedSeconds == startedSeconds
      && current.startedMicroseconds == startedMicroseconds
  }
}
public struct PreparedUpdateInstallation: Sendable {
  public let directory: URL
  public let planURL: URL
  public let version: String
}
struct UpdateInstallPlan: Codable, Sendable {
  let schemaVersion: Int
  let id: UUID
  let target: URL
  let sourceVersion: String
  let sourceBuild: String
  let oldDigest: String
  let newDigest: String
  var oldProcess: UpdateProcessIdentity
  let envelope: Data
  let challenge: String
  var createdAt: Date
}
struct UpdateInstallState: Codable, Sendable {
  let schemaVersion: Int
  let id: UUID
  var phase: String
  var updatedAt: Date
  var helper: UpdateProcessIdentity?
}
struct UpdateLaunchAcknowledgment: Codable, Sendable {
  let schemaVersion: Int
  let id: UUID
  let challenge: String
  let process: UpdateProcessIdentity
  let digest: String
}
struct UpdateInstallerEnvironment: Sendable {
  let validate: @Sendable (URL, ReleaseUpdateConfiguration, String, String) throws -> Void
  let oldRunning: @Sendable (UpdateProcessIdentity) -> Bool
  let candidateRunning: @Sendable (URL) -> Bool
  let launch: @Sendable (URL, URL) throws -> Void
  let allowFixtureDestination: Bool
  let waitSeconds: TimeInterval
  var rollbackLaunch: @Sendable (URL) throws -> Void = { _ in }
  static let production = Self(
    validate: ReleaseUpdateInstaller.validateTrustedApplication, oldRunning: { $0.isStillRunning },
    candidateRunning: ReleaseUpdateInstaller.hasRunningApplication,
    launch: ReleaseUpdateInstaller.launchApplication, allowFixtureDestination: false,
    waitSeconds: 120, rollbackLaunch: ReleaseUpdateInstaller.launchPreviousApplication)
}
/// No elevated privileges. Updates are limited to a writable user-owned CloudNest
/// installation. Every change retains a verified previous app on the same volume.
public enum ReleaseUpdateInstaller {
  public static func prepare(
    staged: StagedRelease, configuration: ReleaseUpdateConfiguration, currentApp: URL
  ) throws -> PreparedUpdateInstallation {
    try prepare(
      staged: staged, configuration: configuration, currentApp: currentApp, oldProcess: .capture(),
      environment: .production)
  }
  static func prepare(
    staged: StagedRelease, configuration: ReleaseUpdateConfiguration, currentApp: URL,
    oldProcess: UpdateProcessIdentity, environment: UpdateInstallerEnvironment
  ) throws -> PreparedUpdateInstallation {
    let service = ReleaseUpdate(configuration: configuration)
    let metadata = try ReleaseUpdate.applicationMetadata(currentApp)
    guard
      let release = try service.verify(
        staged.release.signedEnvelope, currentVersion: metadata.version),
      release.manifest.assetURL.pathExtension == "zip"
    else { throw ReleaseUpdateError.incompatible }
    let oldVersion = metadata.version
    let oldBuild = metadata.build
    guard let oldNumber = UInt64(oldBuild), let newNumber = UInt64(release.manifest.build),
      newNumber > oldNumber
    else { throw ReleaseUpdateError.incompatible }
    try destination(currentApp, fixture: environment.allowFixtureDestination)
    guard oldProcess.uid == getuid(),
      environment.allowFixtureDestination
        || oldProcess.executable
          == currentApp.appendingPathComponent("Contents/MacOS/CloudNest").path,
      environment.allowFixtureDestination || environment.oldRunning(oldProcess)
    else { throw ReleaseUpdateError.application }
    try environment.validate(currentApp, configuration, oldVersion, oldBuild)
    let oldDigest = try UpdateArchive.inventory(currentApp)
    let parent = currentApp.deletingLastPathComponent()
    let parentFD = try FileSafety.openDirectory(parent)
    defer { close(parentFD) }
    var capacity = statfs()
    guard fstatfs(parentFD, &capacity) == 0, capacity.f_bsize > 0,
      capacity.f_bavail <= UInt64.max / UInt64(capacity.f_bsize),
      capacity.f_bavail * UInt64(capacity.f_bsize) > UInt64(release.manifest.bytes) + 16_777_216
    else { throw ReleaseUpdateError.unsafeStage }
    let id = UUID()
    let name = ".CloudNest-update-" + id.uuidString
    guard mkdirat(parentFD, name, 0o700) == 0 else { throw ReleaseUpdateError.unsafeStage }
    let directory = parent.appendingPathComponent(name)
    let dir = try ReleaseUpdate.privateDirectory(directory)
    defer { close(dir) }
    let candidate = try UpdateArchive.extract(
      staged.artifact, size: release.manifest.bytes, sha256: release.manifest.sha256,
      into: directory)
    try environment.validate(
      candidate, configuration, release.manifest.version, release.manifest.build)
    if !environment.allowFixtureDestination {
      guard let next = try ReleaseUpdateConfiguration.atApplication(candidate),
        next.publicKey == configuration.publicKey, next.teamID == configuration.teamID,
        next.feedURL == configuration.feedURL
      else { throw ReleaseUpdateError.configuration }
    }
    let newDigest = try UpdateArchive.inventory(candidate)
    guard try UpdateArchive.inventory(currentApp) == oldDigest else {
      throw ReleaseUpdateError.application
    }
    var random = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
      throw ReleaseUpdateError.application
    }
    let plan = UpdateInstallPlan(
      schemaVersion: 1, id: id, target: currentApp.standardizedFileURL, sourceVersion: oldVersion,
      sourceBuild: oldBuild, oldDigest: oldDigest, newDigest: newDigest, oldProcess: oldProcess,
      envelope: release.signedEnvelope,
      challenge: random.map { String(format: "%02x", $0) }.joined(), createdAt: Date())
    try write(plan, name: "plan.json", directory: directory, exclusive: true)
    try state(plan, "prepared", directory: directory, helper: nil)
    guard fsync(parentFD) == 0 else { throw ReleaseUpdateError.unsafeStage }
    return PreparedUpdateInstallation(
      directory: directory, planURL: directory.appendingPathComponent("plan.json"),
      version: release.manifest.version)
  }
  @discardableResult public static func startHelper(
    _ prepared: PreparedUpdateInstallation, currentApp: URL
  ) throws -> Process {
    let plan: UpdateInstallPlan = try read(prepared.planURL, maximum: 131072)
    guard plan.target.standardizedFileURL == currentApp.standardizedFileURL,
      plan.oldProcess == (try .capture()),
      try UpdateArchive.inventory(currentApp) == plan.oldDigest,
      let config = try ReleaseUpdateConfiguration.atApplication(currentApp)
    else { throw ReleaseUpdateError.application }
    try validateTrustedApplication(currentApp, config, plan.sourceVersion, plan.sourceBuild)
    let executable = currentApp.appendingPathComponent("Contents/Helpers/CloudNestUpdateHelper")
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--install-plan", prepared.planURL.path]
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin", "LANG": "C", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try Task.checkCancellation()
    try process.run()
    return process
  }
  public static func run(planURL: URL) async throws {
    let plan: UpdateInstallPlan = try read(planURL, maximum: 131072)
    guard let config = try ReleaseUpdateConfiguration.atApplication(plan.target),
      try UpdateProcessIdentity.capture().executable
        == plan.target.appendingPathComponent("Contents/Helpers/CloudNestUpdateHelper").path
    else { throw ReleaseUpdateError.application }
    try await execute(planURL: planURL, configuration: config, environment: .production)
  }
  static func execute(
    planURL: URL, configuration: ReleaseUpdateConfiguration, environment: UpdateInstallerEnvironment
  ) async throws {
    let directory = planURL.deletingLastPathComponent()
    let plan: UpdateInstallPlan = try read(planURL, maximum: 131072)
    try validatePlan(plan, directory: directory, fixture: environment.allowFixtureDestination)
    let global = try globalLease(target: plan.target)
    defer { withExtendedLifetime(global) {} }
    let lease = try OperationLease.acquire(catalogDirectory: directory, jobID: plan.id)
    defer { withExtendedLifetime(lease) {} }
    let status: UpdateInstallState = try read(
      directory.appendingPathComponent("state.json"), maximum: 8192)
    guard status.id == plan.id, ["prepared", "waitingForExit", "swapping"].contains(status.phase)
    else { throw ReleaseUpdateError.application }
    let service = ReleaseUpdate(configuration: configuration)
    guard let release = try service.verify(plan.envelope, currentVersion: plan.sourceVersion) else {
      throw ReleaseUpdateError.incompatible
    }
    let candidate = directory.appendingPathComponent("CloudNest.app")
    try checkApp(
      plan.target, configuration, plan.sourceVersion, plan.sourceBuild, plan.oldDigest, environment)
    try checkApp(
      candidate, configuration, release.manifest.version, release.manifest.build, plan.newDigest,
      environment)
    let helper = try? UpdateProcessIdentity.capture()
    try state(plan, "waitingForExit", directory: directory, helper: helper)
    let deadline = ProcessInfo.processInfo.systemUptime + environment.waitSeconds
    while environment.oldRunning(plan.oldProcess) {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        try state(plan, "prepared", directory: directory, helper: nil)
        throw ReleaseUpdateError.application
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard !environment.candidateRunning(plan.target) else {
      try state(plan, "prepared", directory: directory, helper: nil)
      throw ReleaseUpdateError.application
    }
    try checkApp(
      plan.target, configuration, plan.sourceVersion, plan.sourceBuild, plan.oldDigest, environment)
    try checkApp(
      candidate, configuration, release.manifest.version, release.manifest.build, plan.newDigest,
      environment)
    guard !environment.candidateRunning(plan.target) else {
      try state(plan, "prepared", directory: directory, helper: nil)
      throw ReleaseUpdateError.application
    }
    // New app receives only the private request file path, never its nonce.
    try state(plan, "swapping", directory: directory, helper: helper)
    try exchange(target: plan.target, other: candidate)
    try state(plan, "awaitingAcknowledgment", directory: directory, helper: helper)
    do {
      try checkApp(
        plan.target, configuration, release.manifest.version, release.manifest.build,
        plan.newDigest, environment)
      try environment.launch(plan.target, planURL)
      let ackDeadline = ProcessInfo.processInfo.systemUptime + environment.waitSeconds
      while ProcessInfo.processInfo.systemUptime < ackDeadline {
        if let ack: UpdateLaunchAcknowledgment = try? read(
          directory.appendingPathComponent("ack.json"), maximum: 8192), ack.id == plan.id,
          ack.challenge == plan.challenge, ack.digest == plan.newDigest,
          ack.process.uid == getuid(),
          ack.process.executable
            == plan.target.appendingPathComponent("Contents/MacOS/CloudNest").path,
          environment.allowFixtureDestination || ack.process.isStillRunning
        {
          try checkApp(
            plan.target, configuration, release.manifest.version, release.manifest.build,
            plan.newDigest, environment)
          try state(plan, "installed", directory: directory, helper: helper)
          return
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw ReleaseUpdateError.application
    } catch {
      guard !environment.candidateRunning(plan.target) else {
        try state(plan, "needsRecovery", directory: directory, helper: nil)
        throw ReleaseUpdateError.application
      }
      try checkApp(
        candidate, configuration, plan.sourceVersion, plan.sourceBuild, plan.oldDigest, environment)
      guard try UpdateArchive.inventory(plan.target) == plan.newDigest else {
        try state(plan, "needsRecovery", directory: directory, helper: nil)
        throw ReleaseUpdateError.application
      }
      guard !environment.candidateRunning(plan.target) else {
        try state(plan, "needsRecovery", directory: directory, helper: nil)
        throw ReleaseUpdateError.application
      }
      try exchange(target: plan.target, other: candidate)
      try state(plan, "rolledBack", directory: directory, helper: nil)
      try environment.rollbackLaunch(plan.target)
      throw ReleaseUpdateError.application
    }
  }
  /// Call after native startup/catalog checks pass. Unknown arguments or a stale
  /// request never grant permissions or change storage/Brain state.
  public static func acknowledge(
    arguments: [String] = CommandLine.arguments, currentApp: URL = Bundle.main.bundleURL
  ) throws {
    guard let index = arguments.firstIndex(of: "--cloudnest-update-ack") else { return }
    guard arguments.count == index + 2, index == 1 else { throw ReleaseUpdateError.application }
    let file = URL(fileURLWithPath: arguments[index + 1])
    let directory = file.deletingLastPathComponent()
    let plan: UpdateInstallPlan = try read(file, maximum: 131072)
    try validatePlan(plan, directory: directory, fixture: false)
    guard plan.target.standardizedFileURL == currentApp.standardizedFileURL,
      let config = try ReleaseUpdateConfiguration.atApplication(currentApp),
      let release = try ReleaseUpdate(configuration: config).verify(
        plan.envelope, currentVersion: plan.sourceVersion)
    else { throw ReleaseUpdateError.application }
    let status: UpdateInstallState = try read(
      directory.appendingPathComponent("state.json"), maximum: 8192)
    guard status.id == plan.id, status.phase == "awaitingAcknowledgment",
      let helper = status.helper, helper.isStillRunning
    else { throw ReleaseUpdateError.application }
    try validateTrustedApplication(
      currentApp, config, release.manifest.version, release.manifest.build)
    guard try UpdateArchive.inventory(currentApp) == plan.newDigest else {
      throw ReleaseUpdateError.application
    }
    let process = try UpdateProcessIdentity.capture()
    guard process.executable == currentApp.appendingPathComponent("Contents/MacOS/CloudNest").path
    else { throw ReleaseUpdateError.application }
    try write(
      UpdateLaunchAcknowledgment(
        schemaVersion: 1, id: plan.id, challenge: plan.challenge, process: process,
        digest: plan.newDigest), name: "ack.json", directory: directory, exclusive: true)
  }

  public struct Recovery: Identifiable, Sendable {
    public let id: UUID
    public let directory: URL
    public let phase: String
    public let version: String
    public let canRetry: Bool
    public let canRollback: Bool
  }
  public static func recoveries(currentApp: URL = Bundle.main.bundleURL) throws -> [Recovery] {
    let parent = currentApp.deletingLastPathComponent()
    guard
      [
        URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
      ].contains(parent.standardizedFileURL)
    else { return [] }
    return try recoveries(currentApp: currentApp, fixture: false)
  }
  static func recoveries(currentApp: URL, fixture: Bool) throws -> [Recovery] {
    let parent = currentApp.deletingLastPathComponent()
    let parentFD = try FileSafety.openDirectory(parent)
    defer { close(parentFD) }
    let stream = fdopendir(dup(parentFD))
    guard let stream else { throw ReleaseUpdateError.unsafeStage }
    defer { closedir(stream) }
    var rows: [Recovery] = []
    var count = 0
    while let row = readdir(stream) {
      count += 1
      guard count <= 20_000 else { throw ReleaseUpdateError.unsafeStage }
      var raw = row.pointee.d_name
      let capacity = MemoryLayout.size(ofValue: raw)
      let name = withUnsafePointer(to: &raw) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
      }
      guard name.hasPrefix(".CloudNest-update-"),
        let id = UUID(uuidString: String(name.dropFirst(".CloudNest-update-".count)))
      else { continue }
      guard rows.count < 100 else { throw ReleaseUpdateError.unsafeStage }
      let directory = parent.appendingPathComponent(name)
      guard
        let plan: UpdateInstallPlan = try? read(
          directory.appendingPathComponent("plan.json"), maximum: 131072), plan.id == id,
        plan.target.standardizedFileURL == currentApp.standardizedFileURL,
        let status: UpdateInstallState = try? read(
          directory.appendingPathComponent("state.json"), maximum: 8192), status.id == id
      else { continue }
      guard
        (try? validatePlan(plan, directory: directory, fixture: fixture, allowHistorical: true))
          != nil
      else { continue }
      let running = status.helper?.isStillRunning == true
      let target = try? UpdateArchive.inventory(currentApp)
      let other = try? UpdateArchive.inventory(directory.appendingPathComponent("CloudNest.app"))
      rows.append(
        Recovery(
          id: id, directory: directory, phase: running ? "helperRunning" : status.phase,
          version: plan.sourceVersion,
          canRetry: !running && target == plan.oldDigest && other == plan.newDigest,
          canRollback: !running && target == plan.newDigest && other == plan.oldDigest))
    }
    return rows.sorted { $0.id.uuidString < $1.id.uuidString }
  }
  public static func retry(_ recovery: Recovery, currentApp: URL = Bundle.main.bundleURL) throws
    -> PreparedUpdateInstallation
  {
    let file = recovery.directory.appendingPathComponent("plan.json")
    var plan: UpdateInstallPlan = try read(file, maximum: 131072)
    try validatePlan(plan, directory: recovery.directory, fixture: false, allowHistorical: true)
    let lease = try OperationLease.acquire(catalogDirectory: recovery.directory, jobID: plan.id)
    defer { withExtendedLifetime(lease) {} }
    let status: UpdateInstallState = try read(
      recovery.directory.appendingPathComponent("state.json"), maximum: 8192)
    guard plan.id == recovery.id, plan.target.standardizedFileURL == currentApp.standardizedFileURL,
      status.helper?.isStillRunning != true,
      let config = try ReleaseUpdateConfiguration.atApplication(currentApp),
      let release = try ReleaseUpdate(configuration: config).verify(
        plan.envelope, currentVersion: plan.sourceVersion)
    else { throw ReleaseUpdateError.application }
    try checkApp(
      currentApp, config, plan.sourceVersion, plan.sourceBuild, plan.oldDigest, .production)
    try checkApp(
      recovery.directory.appendingPathComponent("CloudNest.app"), config, release.manifest.version,
      release.manifest.build, plan.newDigest, .production)
    plan.oldProcess = try .capture()
    plan.createdAt = Date()
    try write(plan, name: "plan.json", directory: recovery.directory, exclusive: false)
    try state(plan, "prepared", directory: recovery.directory, helper: nil)
    return PreparedUpdateInstallation(
      directory: recovery.directory, planURL: file, version: release.manifest.version)
  }
  public static func startRollback(_ recovery: Recovery, currentApp: URL = Bundle.main.bundleURL)
    throws -> Process
  {
    let plan: UpdateInstallPlan = try read(
      recovery.directory.appendingPathComponent("plan.json"), maximum: 131072)
    try validatePlan(plan, directory: recovery.directory, fixture: false, allowHistorical: true)
    guard plan.target.standardizedFileURL == currentApp.standardizedFileURL, plan.id == recovery.id,
      let config = try ReleaseUpdateConfiguration.atApplication(currentApp)
    else { throw ReleaseUpdateError.application }
    let process = try UpdateProcessIdentity.capture()
    let request = UpdateLaunchAcknowledgment(
      schemaVersion: 1, id: plan.id, challenge: plan.challenge, process: process,
      digest: plan.newDigest)
    let lease = try OperationLease.acquire(catalogDirectory: recovery.directory, jobID: plan.id)
    defer { withExtendedLifetime(lease) {} }
    try checkApp(
      currentApp, config, try ReleaseUpdate.applicationMetadata(currentApp).version,
      try ReleaseUpdate.applicationMetadata(currentApp).build, plan.newDigest, .production)
    try write(request, name: "rollback.json", directory: recovery.directory, exclusive: false)
    let helper = Process()
    helper.executableURL = currentApp.appendingPathComponent(
      "Contents/Helpers/CloudNestUpdateHelper")
    helper.arguments = [
      "--rollback-plan", recovery.directory.appendingPathComponent("plan.json").path,
    ]
    helper.environment = ["PATH": "/usr/bin:/bin:/usr/sbin", "LANG": "C", "LC_ALL": "C"]
    helper.standardInput = FileHandle.nullDevice
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice
    try helper.run()
    return helper
  }
  public static func runRollback(planURL: URL) async throws {
    let plan: UpdateInstallPlan = try read(planURL, maximum: 131072)
    guard let config = try ReleaseUpdateConfiguration.atApplication(plan.target),
      try UpdateProcessIdentity.capture().executable
        == plan.target.appendingPathComponent("Contents/Helpers/CloudNestUpdateHelper").path
    else { throw ReleaseUpdateError.application }
    try await rollback(planURL: planURL, configuration: config, environment: .production)
  }
  static func rollback(
    planURL: URL, configuration: ReleaseUpdateConfiguration, environment: UpdateInstallerEnvironment
  ) async throws {
    let directory = planURL.deletingLastPathComponent()
    let plan: UpdateInstallPlan = try read(planURL, maximum: 131072)
    try validatePlan(
      plan, directory: directory, fixture: environment.allowFixtureDestination,
      allowHistorical: true)
    let global = try globalLease(target: plan.target)
    defer { withExtendedLifetime(global) {} }
    let lease = try OperationLease.acquire(catalogDirectory: directory, jobID: plan.id)
    defer { withExtendedLifetime(lease) {} }
    let request: UpdateLaunchAcknowledgment = try read(
      directory.appendingPathComponent("rollback.json"), maximum: 8192)
    guard request.id == plan.id, request.challenge == plan.challenge,
      request.process.uid == getuid(),
      request.process.executable
        == plan.target.appendingPathComponent("Contents/MacOS/CloudNest").path
    else { throw ReleaseUpdateError.application }
    let deadline = ProcessInfo.processInfo.systemUptime + environment.waitSeconds
    while environment.oldRunning(request.process) {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw ReleaseUpdateError.application
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard !environment.candidateRunning(plan.target) else { throw ReleaseUpdateError.application }
    let previous = directory.appendingPathComponent("CloudNest.app")
    let targetDigest = try UpdateArchive.inventory(plan.target)
    let otherDigest = try UpdateArchive.inventory(previous)
    if targetDigest == plan.oldDigest && otherDigest == plan.newDigest {
      try state(plan, "rolledBack", directory: directory, helper: nil)
      return
    }
    guard targetDigest == plan.newDigest, otherDigest == plan.oldDigest else {
      throw ReleaseUpdateError.integrity
    }
    try checkApp(
      previous, configuration, plan.sourceVersion, plan.sourceBuild, plan.oldDigest, environment)
    try state(plan, "rollingBack", directory: directory, helper: try? .capture())
    guard !environment.candidateRunning(plan.target) else { throw ReleaseUpdateError.application }
    try exchange(target: plan.target, other: previous)
    try state(plan, "rolledBack", directory: directory, helper: nil)
    try environment.rollbackLaunch(plan.target)
  }
  static func validatePlan(
    _ plan: UpdateInstallPlan, directory: URL, fixture: Bool, allowHistorical: Bool = false
  ) throws {
    guard plan.schemaVersion == 1, plan.target.isFileURL,
      plan.target.lastPathComponent == "CloudNest.app",
      directory.lastPathComponent == ".CloudNest-update-" + plan.id.uuidString,
      directory.deletingLastPathComponent().standardizedFileURL
        == plan.target.deletingLastPathComponent().standardizedFileURL,
      plan.challenge.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      plan.createdAt <= Date().addingTimeInterval(60),
      allowHistorical || plan.createdAt > Date().addingTimeInterval(-86400),
      plan.oldProcess.uid == getuid()
    else { throw ReleaseUpdateError.application }
    try destination(plan.target, fixture: fixture)
    let fd = try ReleaseUpdate.privateDirectory(directory)
    close(fd)
  }
  static func globalLease(target: URL) throws -> OperationLease {
    let parent = try FileSafety.openDirectory(target.deletingLastPathComponent())
    defer { close(parent) }
    let name = ".CloudNest-update-lock"
    guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else {
      throw ReleaseUpdateError.unsafeStage
    }
    let directory = target.deletingLastPathComponent().appendingPathComponent(name)
    let verified = try ReleaseUpdate.privateDirectory(directory)
    close(verified)
    guard let id = UUID(uuidString: "07422f1b-4416-4a2e-a188-ea73c76560ea") else {
      throw ReleaseUpdateError.unsafeStage
    }
    return try OperationLease.acquire(catalogDirectory: directory, jobID: id)
  }
  static func destination(_ app: URL, fixture: Bool) throws {
    guard app.isFileURL, app.lastPathComponent == "CloudNest.app",
      !app.path.utf8.contains(where: { $0 < 32 || $0 == 127 })
    else { throw ReleaseUpdateError.installLocation }
    let allowed = [
      URL(fileURLWithPath: "/Applications"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]
    guard fixture || allowed.contains(app.deletingLastPathComponent().standardizedFileURL),
      access(app.deletingLastPathComponent().path, W_OK) == 0
    else { throw ReleaseUpdateError.installLocation }
    let parent = try FileSafety.openDirectory(app.deletingLastPathComponent())
    defer { close(parent) }
    var info = stat()
    guard fstatat(parent, app.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
      info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o022 == 0
    else { throw ReleaseUpdateError.installLocation }
  }
  static func checkApp(
    _ url: URL, _ configuration: ReleaseUpdateConfiguration, _ version: String, _ build: String,
    _ digest: String, _ environment: UpdateInstallerEnvironment
  ) throws {
    guard try UpdateArchive.inventory(url) == digest else { throw ReleaseUpdateError.integrity }
    try environment.validate(url, configuration, version, build)
    guard try UpdateArchive.inventory(url) == digest else { throw ReleaseUpdateError.integrity }
  }
  static func exchange(target: URL, other: URL) throws {
    let parent = try FileSafety.openDirectory(target.deletingLastPathComponent())
    let staging = try ReleaseUpdate.privateDirectory(other.deletingLastPathComponent())
    defer {
      close(parent)
      close(staging)
    }
    var a = stat()
    var b = stat()
    guard fstatat(parent, target.lastPathComponent, &a, AT_SYMLINK_NOFOLLOW) == 0,
      fstatat(staging, other.lastPathComponent, &b, AT_SYMLINK_NOFOLLOW) == 0, a.st_dev == b.st_dev,
      a.st_mode & S_IFMT == S_IFDIR, b.st_mode & S_IFMT == S_IFDIR,
      renameatx_np(
        parent, target.lastPathComponent, staging, other.lastPathComponent, UInt32(RENAME_SWAP))
        == 0, fsync(parent) == 0, fsync(staging) == 0
    else { throw ReleaseUpdateError.application }
  }
  static func state(
    _ plan: UpdateInstallPlan, _ phase: String, directory: URL, helper: UpdateProcessIdentity?
  ) throws {
    try write(
      UpdateInstallState(
        schemaVersion: 1, id: plan.id, phase: phase, updatedAt: Date(), helper: helper),
      name: "state.json", directory: directory, exclusive: false)
  }
  static func write<T: Encodable>(_ value: T, name: String, directory: URL, exclusive: Bool) throws
  {
    let fd = try ReleaseUpdate.privateDirectory(directory)
    defer { close(fd) }
    let temporary = ".pending-" + UUID().uuidString
    let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw ReleaseUpdateError.unsafeStage }
    let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
    defer {
      try? handle.close()
      unlinkat(fd, temporary, 0)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try handle.write(contentsOf: encoder.encode(value))
    try handle.synchronize()
    try handle.close()
    if exclusive {
      guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0 else {
        throw ReleaseUpdateError.unsafeStage
      }
    } else {
      var existing = stat()
      if fstatat(fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
        guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid(),
          existing.st_mode & 0o077 == 0, existing.st_nlink == 1
        else { throw ReleaseUpdateError.unsafeStage }
      } else if errno != ENOENT {
        throw ReleaseUpdateError.unsafeStage
      }
      guard renameat(fd, temporary, fd, name) == 0 else { throw ReleaseUpdateError.unsafeStage }
    }
    guard fsync(fd) == 0 else { throw ReleaseUpdateError.unsafeStage }
  }
  static func read<T: Decodable>(_ url: URL, maximum: Int) throws -> T {
    let parent = try ReleaseUpdate.privateDirectory(url.deletingLastPathComponent())
    defer { close(parent) }
    let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ReleaseUpdateError.unsafeStage }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
      before.st_mode & 0o077 == 0, before.st_nlink == 1, before.st_size > 0,
      before.st_size <= maximum
    else { throw ReleaseUpdateError.unsafeStage }
    let data =
      try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1)
      ?? Data()
    var after = stat()
    var named = stat()
    guard data.count == before.st_size, fstat(fd, &after) == 0,
      FileSafety.identity(before) == FileSafety.identity(after),
      fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
      FileSafety.identity(after) == FileSafety.identity(named)
    else { throw ReleaseUpdateError.unsafeStage }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
  }
  static func validateTrustedApplication(
    _ app: URL, _ config: ReleaseUpdateConfiguration, _ version: String, _ build: String
  ) throws {
    let metadata = try ReleaseUpdate.applicationMetadata(app)
    guard metadata.version == version, metadata.build == build else {
      throw ReleaseUpdateError.application
    }
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let rule =
      "anchor apple generic and certificate leaf[subject.OU] = \"\(config.teamID)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"org.cloudnest.os\""
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
      SecStaticCodeCheckValidity(
        code,
        SecCSFlags(
          rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode),
        requirement)
        == errSecSuccess
    else { throw ReleaseUpdateError.application }
    try ReleaseUpdate.notarized(app)
  }
  static func hasRunningApplication(_ app: URL) -> Bool {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return true }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let read = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard read > 0, read < pids.count else { return true }
    let executable = app.appendingPathComponent("Contents/MacOS/CloudNest").path
    return pids.prefix(Int(read)).contains { pid in
      guard pid > 0, let info = try? UpdateProcessIdentity.capture(pid) else { return false }
      return info.uid == getuid() && info.executable == executable
    }
  }
  static func launchPreviousApplication(_ app: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", app.path]
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }
  static func launchApplication(_ app: URL, _ request: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", app.path, "--args", "--cloudnest-update-ack", request.path]
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let end = ProcessInfo.processInfo.systemUptime + 10
    while process.isRunning {
      guard ProcessInfo.processInfo.systemUptime < end else {
        process.terminate()
        throw ReleaseUpdateError.application
      }
      usleep(10_000)
    }
    guard process.terminationStatus == 0 else { throw ReleaseUpdateError.application }
  }
}
