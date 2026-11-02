import Foundation

/// Main-thread ownership survives view recreation. A stale task cannot release
/// another operation, and even stale UI callbacks must acquire before working.
@MainActor public final class ForegroundOperationGate {
    private var owner: UUID?
    public init() {}
    public func acquire() -> UUID? {
        guard owner == nil else { return nil }
        let id = UUID(); owner = id; return id
    }
    @discardableResult public func release(_ id: UUID) -> Bool {
        guard owner == id else { return false }
        owner = nil; return true
    }
}
