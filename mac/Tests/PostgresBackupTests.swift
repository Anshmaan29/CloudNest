import Testing
import Foundation
import Darwin
@testable import CloudNestCore

private struct PostgresFixture: Sendable {
    let f: Fixture
    let destination: URL
    let binary: URL
    let socket: URL
    let listener: Int32
    let containerID = String(repeating: "a", count: 64)
    let payload = Data("PGDMP-disposable-command-contract-fixture".utf8)
    init() throws {
        f = try Fixture(); destination = f.base.appendingPathComponent("PostgresDestination"); binary = f.base.appendingPathComponent("fake-docker")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        socket = URL(fileURLWithPath: "/tmp/cnp-" + UUID().uuidString.prefix(12) + ".sock")
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0); try #require(listener >= 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); let name = Array(socket.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for index in name.indices { buffer[index] = UInt8(bitPattern: name[index]) } }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }; try #require(result == 0)
        let script = """
        #!/usr/bin/python3
        import sys,os,json,time
        root=os.path.dirname(os.path.realpath(__file__)); args=sys.argv[1:]
        with open(root+'/calls','a') as out: out.write(json.dumps(args)+'\\n')
        with open(root+'/environment','w') as out: json.dump(dict(os.environ),out)
        with open(args[1]+'/config.json') as config:
          if json.load(config)!={'auths':{}}: sys.exit(91)
        mode=open(root+'/mode').read(); cmd=args[4:]; payload=b'PGDMP-disposable-command-contract-fixture'
        if cmd[:2]==['container','inspect']:
          print(('b' if mode=='changed' else 'a')*64, 'false' if mode=='stopped' else 'true'); sys.exit(0)
        if cmd[0]!='exec': sys.exit(92)
        if 'pg_dump' in cmd:
          sys.stdout.buffer.write(payload); sys.stdout.flush()
          if mode=='dumpfail': sys.exit(7)
          if mode=='slow': time.sleep(10)
        elif 'createdb' in cmd:
          if mode=='exists': sys.exit(8)
          open(root+'/created-database','w').write(cmd[-1])
        elif 'pg_restore' in cmd:
          received=sys.stdin.buffer.read()
          if received!=payload: sys.exit(9)
          if '--list' in cmd:
            if mode=='listfail': sys.exit(10)
            if mode=='tamper': open(args[1]+'/approved.pgdump','wb').write(b'changed-private-copy')
            print('; Archive created at fixture time\\n; TOC Entries: fixture')
          else:
            open(root+'/restored-database','w').write(cmd[-1])
            if mode=='restorefail': sys.exit(11)
        else: sys.exit(93)
        """
        try Data(script.utf8).write(to: binary); try #require(chmod(binary.path, 0o700) == 0); try mode("ok")
    }
    func mode(_ value: String) throws { try Data(value.utf8).write(to: f.base.appendingPathComponent("mode")) }
    func driver(limits: PostgresBackupLimits = PostgresBackupLimits(), protected: [URL] = []) -> PostgresBackup { PostgresBackup(executable: binary, socket: socket, protectedRoots: protected, limits: limits) }
    func calls() throws -> [[String]] { guard let data = try? String(contentsOf: f.base.appendingPathComponent("calls"), encoding: .utf8) else { return [] }; return try data.split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } }
    func published() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix("PostgresBackup-") } }
    func clean() { close(listener); unlink(socket.path); f.clean() }
    func backup() throws -> (ResolvedPostgresContainer, PostgresBackupResult) { let container = try driver().resolve(container: "selected-postgres"); return (container, try driver().dump(container: container, database: "appdata", role: "postgres", to: destination)) }
}

@Test func postgresCommandContractUsesImmutableContainerPrivateEnvironmentSocketAndCustomList() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let (_, backup) = try f.backup()
    #expect(try Data(contentsOf: backup.directory.appendingPathComponent(PostgresBackup.archiveName)) == f.payload)
    #expect(!backup.manifest.permitsOriginalCleanup)
    let calls = try f.calls(), executions = calls.filter { $0.contains("exec") }
    #expect(executions.count == 2)
    #expect(executions[0].contains("pg_dump") && executions[1].contains("--list"))
    for call in executions {
        #expect(call[0] == "--config" && call[2] == "--host" && call[3] == "unix://" + f.socket.path)
        #expect(call.contains(f.containerID) && !call.contains("selected-postgres"))
        #expect(call.contains("--user") && call.contains("postgres") && call.contains("/usr/bin/env") && call.contains("-i"))
        #expect(call.contains("/usr/bin/timeout") && call.contains("-k") && call.contains("PGPASSFILE=/dev/null"))
        #expect(!call.contains("sh") && !call.contains("-c") && !call.contains("--tty"))
    }
    #expect(executions[0].contains("/var/run/postgresql") && executions[0].contains("--no-password") && executions[0].contains("--format=custom"))
    let environment = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: f.f.base.appendingPathComponent("environment")))
    #expect(environment["HOME"] == nil && environment["DOCKER_HOST"] == nil && environment["PGPASSWORD"] == nil)
}
@Test func postgresRestoreCreatesOnlyGeneratedNewDatabaseBeforeTransactionalRestore() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let (container, backup) = try f.backup(), driver = f.driver()
    let review = try PostgresBackup.review(directory: backup.directory), plan = try driver.planRestore(approved: review, container: container, role: "postgres")
    let other = try driver.planRestore(approved: review, container: container, role: "postgres")
    #expect(plan.databaseName != other.databaseName && plan.databaseName.hasPrefix("cloudnest_restore_"))
    let result = try driver.restore(plan: plan)
    #expect(result.databaseName == plan.databaseName)
    let calls = try f.calls(), created = try #require(calls.firstIndex { $0.contains("createdb") }), restored = try #require(calls.firstIndex { $0.contains("--single-transaction") })
    #expect(created < restored && calls[created].last == plan.databaseName && calls[restored].last == plan.databaseName)
    for flag in ["--single-transaction", "--exit-on-error", "--no-owner", "--no-privileges"] { #expect(calls[restored].contains(flag)) }
    #expect(calls[created].contains("template0"))
    #expect(!calls.contains { $0.contains("dropdb") || $0.contains("--clean") || $0.contains("--create") || $0.contains("pull") || $0.contains("start") || $0.contains("volume") })
    #expect(FileManager.default.fileExists(atPath: result.recoveryDirectory.appendingPathComponent("03-restored.json").path))
    #expect(!FileManager.default.fileExists(atPath: result.recoveryDirectory.appendingPathComponent("approved.pgdump").path))
}
@Test func postgresInvalidIdentifiersStoppedOrChangedContainersNeverDump() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let driver = f.driver()
    for ref in ["--help", "a/b", "a b", "x;echo", ""] { #expect(throws: (any Error).self) { try driver.resolve(container: ref) } }
    #expect(try f.calls().isEmpty)
    let container = try driver.resolve(container: "selected-postgres")
    for value in ["--help", "db;drop", "db/password", "x y", "", String(repeating: "a", count: 64)] {
        #expect(throws: (any Error).self) { try driver.dump(container: container, database: value, role: "postgres", to: f.destination) }
        #expect(throws: (any Error).self) { try driver.dump(container: container, database: "appdata", role: value, to: f.destination) }
    }
    try f.mode("stopped"); #expect(throws: (any Error).self) { try driver.dump(container: container, database: "appdata", role: "postgres", to: f.destination) }
    try f.mode("changed"); #expect(throws: (any Error).self) { try driver.dump(container: container, database: "appdata", role: "postgres", to: f.destination) }
    #expect(!(try f.calls()).contains { $0.contains("pg_dump") })
}
@Test func postgresDumpOrArchiveListFailureNeverPublishesBackup() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let container = try f.driver().resolve(container: "selected-postgres")
    for mode in ["dumpfail", "listfail"] { try f.mode(mode); #expect(throws: (any Error).self) { try f.driver().dump(container: container, database: "appdata", role: "postgres", to: f.destination) } }
    #expect(try f.published().isEmpty)
}
@Test func postgresMismatchAndExistingDatabaseRefuseRestoreWithoutOverwritingOrDropping() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let (container, backup) = try f.backup(), driver = f.driver()
    let review = try PostgresBackup.review(directory: backup.directory), plan = try driver.planRestore(approved: review, container: container, role: "postgres")
    let before = try f.calls().count, payload = backup.directory.appendingPathComponent(PostgresBackup.archiveName)
    try Data("mismatched".utf8).write(to: payload)
    #expect(throws: (any Error).self) { try driver.restore(plan: plan) }
    #expect(try f.calls().count == before)
    try f.payload.write(to: payload); try f.mode("exists")
    #expect(throws: PostgresRestoreFailure.self) { try driver.restore(plan: plan) }
    #expect(!(try f.calls()).contains { $0.contains("--single-transaction") || $0.contains("dropdb") })
}
@Test func postgresRestoreFailureRetainsNewDatabaseJournalAndVerifiedCopy() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let (container, backup) = try f.backup(), driver = f.driver()
    let plan = try driver.planRestore(approved: PostgresBackup.review(directory: backup.directory), container: container, role: "postgres")
    try f.mode("restorefail")
    do { _ = try driver.restore(plan: plan); Issue.record("expected restore failure") }
    catch let failure as PostgresRestoreFailure {
        #expect(failure.databaseName == plan.databaseName)
        #expect(FileManager.default.fileExists(atPath: failure.recoveryDirectory.appendingPathComponent("02-created.json").path))
        #expect(try Data(contentsOf: failure.recoveryDirectory.appendingPathComponent("approved.pgdump")) == f.payload)
    }
    #expect(!(try f.calls()).contains { $0.contains("dropdb") })
}
@Test func postgresCancellationTimeoutOutputAndDiskBudgetsRetainStaging() async throws {
    let f = try PostgresFixture(); defer { f.clean() }; let container = try f.driver().resolve(container: "selected-postgres")
    var limits = PostgresBackupLimits(); limits.maximumBytes = 6
    #expect(throws: (any Error).self) { try f.driver(limits: limits).dump(container: container, database: "appdata", role: "postgres", to: f.destination) }
    limits = PostgresBackupLimits(); limits.minimumFreeBytes = Int64.max
    #expect(throws: (any Error).self) { try f.driver(limits: limits).dump(container: container, database: "appdata", role: "postgres", to: f.destination) }
    limits = PostgresBackupLimits(); limits.transferTimeout = 0.1; try f.mode("slow")
    #expect(throws: (any Error).self) { try f.driver(limits: limits).dump(container: container, database: "appdata", role: "postgres", to: f.destination) }
    try f.mode("ok")
    let task = Task { try f.driver().dump(container: container, database: "appdata", role: "postgres", to: f.destination) { _ in withUnsafeCurrentTask { $0?.cancel() } } }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try f.published().isEmpty)
}

@Test func postgresRestoreRevalidatesListAndPrivateCopyBeforeCreatingDatabase() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let (container, backup) = try f.backup(), driver = f.driver()
    let review = try PostgresBackup.review(directory: backup.directory)
    for mode in ["listfail", "tamper"] {
        try f.mode(mode)
        let plan = try driver.planRestore(approved: review, container: container, role: "postgres")
        #expect(throws: PostgresRestoreFailure.self) { try driver.restore(plan: plan) }
    }
    #expect(!(try f.calls()).contains { $0.contains("createdb") || $0.contains("--single-transaction") })
    #expect(try Data(contentsOf: backup.directory.appendingPathComponent(PostgresBackup.archiveName)) == f.payload)
}

@Test func postgresProtectedDestinationsAndLinkedOrChangedManifestsRefuseBeforeExec() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let (container, backup) = try f.backup()
    #expect(throws: (any Error).self) { try f.driver(protected: [f.destination]).dump(container: container, database: "appdata", role: "postgres", to: f.destination) }
    let review = try PostgresBackup.review(directory: backup.directory), plan = try f.driver().planRestore(approved: review, container: container, role: "postgres"), before = try f.calls().count
    let payload = backup.directory.appendingPathComponent(PostgresBackup.archiveName), alternate = f.f.base.appendingPathComponent("archive-held")
    try FileManager.default.moveItem(at: payload, to: alternate); try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: alternate)
    #expect(throws: (any Error).self) { try f.driver().restore(plan: plan) }
    try FileManager.default.removeItem(at: payload); try FileManager.default.moveItem(at: alternate, to: payload)
    let original = try Data(contentsOf: backup.manifestURL); try (original + Data(" ".utf8)).write(to: backup.manifestURL)
    #expect(throws: (any Error).self) { try f.driver().restore(plan: plan) }
    #expect(try f.calls().count == before)
}

@Test func postgresPublicationConflictPreservesExistingUserFiles() throws {
    let f = try PostgresFixture(); defer { f.clean() }; let container = try f.driver().resolve(container: "selected-postgres")
    #expect(throws: (any Error).self) {
        try f.driver().dump(container: container, database: "appdata", role: "postgres", to: f.destination) { _ in
            let recovery = f.destination.appendingPathComponent(".cloudnest-recovery")
            if let name = try? FileManager.default.contentsOfDirectory(atPath: recovery.path).first {
                let target = f.destination.appendingPathComponent("PostgresBackup-" + name.dropFirst("postgres-".count))
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try? Data("retain-existing-user-file".utf8).write(to: target.appendingPathComponent("sentinel"))
            }
        }
    }
    let name = try #require(f.published().first)
    #expect(try Data(contentsOf: f.destination.appendingPathComponent(name).appendingPathComponent("sentinel")) == Data("retain-existing-user-file".utf8))
}
