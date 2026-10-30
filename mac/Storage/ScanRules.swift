import Foundation

public enum ScanPreset: String, CaseIterable, Sendable, Codable {
    case safe = "Safe", balanced = "Balanced", aggressive = "Aggressive"
    public var minimumBytes: Int64 { switch self { case .safe: 100_000_000; case .balanced: 25_000_000; case .aggressive: 10_000_000 } }
    public var minimumAgeDays: Int { switch self { case .safe: 180; case .balanced: 60; case .aggressive: 14 } }
}

public struct DuplicateGroup: Sendable, Identifiable {
    public var id: String { sha256 }
    public let sha256: String
    public let files: [URL]
    public let logicalBytesPerFile: Int64
}

extension FileScanner {
    /// Bounded, opt-in hashing after metadata scan. Equal sizes only; hard links
    /// were already deduplicated. These are recommendations, never deletion rules.
    public func duplicateGroups(_ report: ScanReport, root: URL, byteBudget: Int64 = 2_000_000_000) throws -> [DuplicateGroup] {
        let sizes = Dictionary(grouping: report.candidates, by: \.logicalBytes)
        var remaining = byteBudget, groups: [String: [URL]] = [:], groupSizes: [String: Int64] = [:]
        for (size, candidates) in sizes.sorted(by: { $0.key < $1.key }) where candidates.count > 1 {
            for candidate in candidates {
                guard size <= remaining else { continue }
                try Task.checkCancellation(); remaining -= size
                let snapshot = try safety.snapshot(candidate.url, root: root)
                groups[snapshot.sha256, default: []].append(candidate.url); groupSizes[snapshot.sha256] = size
            }
        }
        return groups.filter { $0.value.count > 1 }.map { DuplicateGroup(sha256: $0.key, files: $0.value, logicalBytesPerFile: groupSizes[$0.key]!) }.sorted { $0.id < $1.id }
    }
}
