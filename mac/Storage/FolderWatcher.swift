import Foundation
import CoreServices

private final class ChangeHandler: Sendable {
    let changed: @Sendable () -> Void
    init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
}

/// One event stream for one approved folder. Events mark results stale; they
/// never trigger rescanning, hashing, uploads, or cleanup by themselves.
public final class FolderWatcher: @unchecked Sendable {
    private let stream: FSEventStreamRef
    public init(root: URL, changed: @escaping @Sendable () -> Void) throws {
        let handler = ChangeHandler(changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(), retain: { pointer in
            guard let pointer else { return nil }
            _ = Unmanaged<ChangeHandler>.fromOpaque(pointer).retain(); return pointer
        }, release: { pointer in
            if let pointer { Unmanaged<ChangeHandler>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        guard let created = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            if let info { Unmanaged<ChangeHandler>.fromOpaque(info).takeUnretainedValue().changed() }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { throw NestError.unsafePath("folder events unavailable") }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "org.cloudnest.folder-events", qos: .utility))
        guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); throw NestError.unsafePath("folder events unavailable") }
    }
    deinit { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
}
