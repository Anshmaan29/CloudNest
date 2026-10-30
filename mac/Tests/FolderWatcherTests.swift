import Testing
import Foundation
@testable import CloudNestCore

@Test func approvedFolderEmitsAChangeWithoutPollingOrScanning() async throws {
    let f = try Fixture(); defer { f.clean() }
    let (events, continuation) = AsyncStream<Void>.makeStream()
    let watcher = try FolderWatcher(root: f.base) { continuation.yield(()) }
    defer { withExtendedLifetime(watcher) {}; continuation.finish() }
    try Data("event".utf8).write(to: f.base.appendingPathComponent("event.txt"))
    let changed = await withTaskGroup(of: Bool.self) { group in
        group.addTask { for await _ in events { return true }; return false }
        group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
        let result = await group.next() ?? false
        group.cancelAll(); return result
    }
    #expect(changed)
}
