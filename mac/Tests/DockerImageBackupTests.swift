import Testing
import Foundation
import Darwin
@testable import CloudNestCore

private struct DockerFixture: Sendable {
    let base: URL
    let destination: URL
    let binary: URL
    let endpoint: URL
    let listener: Int32
    let imageID = "sha256:" + String(repeating: "a", count: 64)
    let payload = Data("cloudnest-disposable-image-fixture".utf8)
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    init() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Spotlight must not become an unrelated reader of these disposable workflow fixtures.
        // Keep the production file-in-use guard fully enforced, including for system readers.
        base = repo.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/docker-tests-" + UUID().uuidString + ".noindex")
        destination = base.appendingPathComponent("Destination"); binary = base.appendingPathComponent("fake-docker")
        endpoint = URL(fileURLWithPath: "/tmp/cnd-" + UUID().uuidString.prefix(12) + ".sock")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NestError.invalidResponse }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let name = Array(endpoint.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for index in name.indices { buffer[index] = UInt8(bitPattern: name[index]) } }
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(listener); throw NestError.invalidResponse }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" >>\(Self.quote(base.appendingPathComponent("argv").path))
        printf '\\036\\n' >>\(Self.quote(base.appendingPathComponent("argv").path))
        /usr/bin/env >\(Self.quote(base.appendingPathComponent("environment").path))
        mode=$(/bin/cat \(Self.quote(base.appendingPathComponent("mode").path)))
        case "$5 $6" in
          'version --format') printf '99.0-fixture\\n';;
          'image inspect')
            if [ "$mode" = invalid ]; then printf 'not-an-image-id\\n'; else printf '%s\\n' \(Self.quote(imageID)); fi;;
          'image save')
            printf '%s' 'cloudnest-disposable-image-fixture'
            if [ "$mode" = fail ]; then exit 7; fi
            if [ "$mode" = slow ]; then exec /bin/sleep 10; fi;;
          'image load') /bin/cat >\(Self.quote(base.appendingPathComponent("received").path));;
          *) exit 44;;
        esac
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try mode("ok")
    }
    func mode(_ value: String) throws { try Data(value.utf8).write(to: base.appendingPathComponent("mode")) }
    func driver(limits: DockerBackupLimits = DockerBackupLimits(), protected: [URL] = []) -> DockerImageBackup { DockerImageBackup(executable: binary, socket: endpoint, protectedRoots: protected, limits: limits) }
    func calls() throws -> [[String]] {
        let text = try String(contentsOf: base.appendingPathComponent("argv"), encoding: .utf8)
        return text.components(separatedBy: "\u{1e}\n").filter { !$0.isEmpty }.map { value in
            var arguments = value.components(separatedBy: "\n"); if arguments.last == "" { arguments.removeLast() }; return arguments
        }
    }
    func published() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix("DockerImage-") } }
    func clean() { close(listener); unlink(endpoint.path); try? FileManager.default.removeItem(at: base) }
}
private final class DockerOnce: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func run(_ action: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; action() } }
}

@Test func dockerBackupUsesImmutableIDFixedArgumentsAndCredentialFreeEnvironment() throws {
    let f = try DockerFixture(); defer { f.clean() }
    let driver = f.driver()
    #expect(try driver.checkConnection() == "99.0-fixture")
    let image = try driver.resolve(reference: "example.local/project:stable")
    let saved = try driver.export(image: image, to: f.destination)
    #expect(image.id == f.imageID)
    #expect(try Data(contentsOf: saved.directory.appendingPathComponent("image.tar")) == f.payload)
    #expect(saved.manifest.bytes == Int64(f.payload.count))
    #expect(try f.published().count == 1)
    for call in try f.calls() {
        #expect(call.count >= 6)
        #expect(call[0] == "--config" && call[2] == "--host" && call[3] == "unix://" + f.endpoint.path)
        #expect(call[1].contains("cloudnest-docker-"))
    }
    #expect(try f.calls().contains { Array($0.dropFirst(4)) == ["image", "save", f.imageID] })
    for call in try f.calls() where call.count > 5 && call[5] == "inspect" {
        #expect(Array(call.dropFirst(4)).prefix(4) == ["image", "inspect", "--format", "{{.ID}}"])
    }
    #expect(!(try f.calls()).contains { $0.contains("pull") || $0.contains("run") || $0.contains("stop") || $0.contains("volume") })
    let environment = try String(contentsOf: f.base.appendingPathComponent("environment"), encoding: .utf8)
    #expect(!environment.contains("DOCKER_") && !environment.contains("GIT_") && !environment.contains("HOME="))
    let review = try DockerImageBackup.review(directory: saved.directory)
    try driver.importBackup(approved: review)
    #expect(try Data(contentsOf: f.base.appendingPathComponent("received")) == f.payload)
    #expect(try f.calls().contains { Array($0.dropFirst(4)) == ["image", "load", "--quiet"] })
}

@Test func dockerRejectsUnsafeReferencesAndUnresolvedIDsBeforeSaving() throws {
    let f = try DockerFixture(); defer { f.clean() }
    for value in ["--help", "image;echo bad", "a b", "a\nb", ""] { #expect(throws: (any Error).self) { try f.driver().resolve(reference: value) } }
    #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("argv").path))
    try f.mode("invalid")
    #expect(throws: (any Error).self) { try f.driver().resolve(reference: "fixture:latest") }
    #expect(try f.published().isEmpty)
}

@Test func dockerFailedOrOversizeExportNeverPublishesPartialArchive() throws {
    let f = try DockerFixture(); defer { f.clean() }
    let image = try f.driver().resolve(reference: "fixture:latest")
    try f.mode("fail")
    #expect(throws: (any Error).self) { try f.driver().export(image: image, to: f.destination) }
    try f.mode("ok"); var limit = DockerBackupLimits(); limit.maximumBytes = 4
    #expect(throws: (any Error).self) { try f.driver(limits: limit).export(image: image, to: f.destination) }
    #expect(try f.published().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.appendingPathComponent(".cloudnest-recovery").path).count == 2)
}

@Test func dockerExportTimeoutAndCancellationStopOnlyOwnedCLI() async throws {
    let f = try DockerFixture(); defer { f.clean() }
    let image = try f.driver().resolve(reference: "fixture:latest"); try f.mode("slow")
    var limits = DockerBackupLimits(); limits.transferTimeout = 0.15
    #expect(throws: (any Error).self) { try f.driver(limits: limits).export(image: image, to: f.destination) }
    let job = Task.detached { try f.driver().export(image: image, to: f.destination) }
    try await Task.sleep(for: .milliseconds(150)); job.cancel()
    do { _ = try await job.value; Issue.record("cancelled export unexpectedly completed") } catch is CancellationError {} catch { Issue.record("expected cancellation, got \(error)") }
    #expect(try f.published().isEmpty)
    // The unrelated fixture Unix socket remains open; no daemon or process-name kill is used.
    var info = stat(); #expect(lstat(f.endpoint.path, &info) == 0 && fcntl(f.listener, F_GETFD) >= 0)
}

@Test func dockerRefusesProtectedSymlinkAndExistingDestinationsWithoutOverwrite() throws {
    let f = try DockerFixture(); defer { f.clean() }
    let image = try f.driver().resolve(reference: "fixture:latest")
    #expect(throws: (any Error).self) { try f.driver(protected: [f.destination]).export(image: image, to: f.destination) }
    let link = f.base.appendingPathComponent("Link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.destination)
    #expect(throws: (any Error).self) { try f.driver().export(image: image, to: link) }
    let once = DockerOnce()
    #expect(throws: (any Error).self) {
        try f.driver().export(image: image, to: f.destination) { _ in once.run {
            let recovery = f.destination.appendingPathComponent(".cloudnest-recovery")
            if let name = try? FileManager.default.contentsOfDirectory(atPath: recovery.path).first {
                let final = f.destination.appendingPathComponent("DockerImage-" + name.dropFirst("docker-".count))
                try? FileManager.default.createDirectory(at: final, withIntermediateDirectories: false)
                try? Data("retain this existing user file".utf8).write(to: final.appendingPathComponent("sentinel"))
            }
        } }
    }
    let existing = try #require(f.published().first)
    #expect(try String(contentsOf: f.destination.appendingPathComponent(existing).appendingPathComponent("sentinel"), encoding: .utf8) == "retain this existing user file")
}

@Test func dockerImportRejectsHashMismatchChangedManifestAndSymlinksBeforeLoad() throws {
    let f = try DockerFixture(); defer { f.clean() }
    let saved = try f.driver().export(image: f.driver().resolve(reference: "fixture:latest"), to: f.destination)
    let review = try DockerImageBackup.review(directory: saved.directory)
    let archive = saved.directory.appendingPathComponent("image.tar"), metadata = saved.manifestURL
    try Data(repeating: 0, count: f.payload.count).write(to: archive)
    #expect(throws: (any Error).self) { try f.driver().importBackup(approved: review) }
    #expect(!(try f.calls()).contains { $0.contains("load") })
    try f.payload.write(to: archive)
    let original = try Data(contentsOf: metadata)
    try (original + Data(" ".utf8)).write(to: metadata)
    #expect(throws: (any Error).self) { try f.driver().importBackup(approved: review) }
    try original.write(to: metadata)
    try FileManager.default.removeItem(at: archive)
    let alternate = f.base.appendingPathComponent("Alternate.tar"); try f.payload.write(to: alternate)
    try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: alternate)
    #expect(throws: (any Error).self) { try f.driver().importBackup(approved: review) }
    #expect(!(try f.calls()).contains { $0.contains("load") })
    try FileManager.default.removeItem(at: metadata)
    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: alternate)
    #expect(throws: (any Error).self) { try DockerImageBackup.review(directory: saved.directory) }
}

@Test func dockerDetectsChangedStagingWithoutPublishingIt() throws {
    let f = try DockerFixture(); defer { f.clean() }
    let image = try f.driver().resolve(reference: "fixture:latest"), once = DockerOnce()
    #expect(throws: (any Error).self) {
        try f.driver().export(image: image, to: f.destination) { _ in once.run {
            let root = f.destination.appendingPathComponent(".cloudnest-recovery")
            if let name = try? FileManager.default.contentsOfDirectory(atPath: root.path).first {
                try? Data("unexpected replacement".utf8).write(to: root.appendingPathComponent(name).appendingPathComponent("image.tar"))
            }
        } }
    }
    #expect(try f.published().isEmpty)
}

@Test func dockerRejectsUnsafeExecutableSocketAndReadableStaging() throws {
    let f = try DockerFixture(); defer { f.clean() }
    let missing = DockerImageBackup(executable: f.binary, socket: f.base.appendingPathComponent("missing.sock"))
    #expect(throws: (any Error).self) { try missing.checkConnection() }
    #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("argv").path))
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: f.binary.path)
    #expect(throws: (any Error).self) { try f.driver().checkConnection() }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.binary.path)
    let image = try f.driver().resolve(reference: "fixture:latest")
    let staging = f.destination.appendingPathComponent(".cloudnest-recovery")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    #expect(throws: (any Error).self) { try f.driver().export(image: image, to: f.destination) }
    #expect(!(try f.calls()).contains { $0.contains("save") })
    #expect(try f.published().isEmpty)
}

@Test func dockerImportRejectsHardLinksAndManifestTraversalBeforeLoad() throws {
    let f = try DockerFixture(); defer { f.clean() }
    let saved = try f.driver().export(image: f.driver().resolve(reference: "fixture:latest"), to: f.destination)
    let review = try DockerImageBackup.review(directory: saved.directory)
    try FileManager.default.linkItem(at: saved.directory.appendingPathComponent("image.tar"), to: f.base.appendingPathComponent("linked.tar"))
    #expect(throws: (any Error).self) { try f.driver().importBackup(approved: review) }
    #expect(!(try f.calls()).contains { $0.contains("load") })
    let original = try Data(contentsOf: saved.manifestURL)
    var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    object["archiveName"] = "../../outside.tar"
    try JSONSerialization.data(withJSONObject: object).write(to: saved.manifestURL)
    #expect(throws: (any Error).self) { try DockerImageBackup.review(directory: saved.directory) }
}
