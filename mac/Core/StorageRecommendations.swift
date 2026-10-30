import Foundation
import Darwin

public struct RecommendationRules: Codable, Sendable, Equatable {
    public var excludedExtensions: [String] = []
    public var excludedPathComponents: [String] = []
    public init() {}
    public func excludes(_ url: URL) -> Bool {
        let extensions = Set(excludedExtensions.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }.filter { !$0.isEmpty })
        let components = Set(excludedPathComponents.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        return extensions.contains(url.pathExtension.lowercased()) || url.pathComponents.contains { components.contains($0.lowercased()) }
    }
    public func filter(_ report: ScanReport) -> ScanReport {
        var filtered = report
        filtered.candidates = report.candidates.filter { !excludes($0.url) }
        filtered.excluded += report.candidates.count - filtered.candidates.count
        return filtered
    }
}
public struct SpaceRecommendation: Sendable, Identifiable {
    public var id: String { candidate.id }
    public let candidate: Candidate
    public let rank: Int
    public let reason: String
}
public struct StorageBreakdown: Sendable, Identifiable {
    public let id: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let files: Int
}
public enum SpaceRescue {
    public static func nonoverlappingRoots(_ roots: [URL]) -> [URL] {
        var selected: [URL] = []
        for root in roots.sorted(by: { $0.pathComponents.count == $1.pathComponents.count ? $0.path < $1.path : $0.pathComponents.count < $1.pathComponents.count }) {
            if !selected.contains(where: { FileSafety.contains($0, root) }) { selected.append(root) }
        }
        return selected
    }
    public static func merge(_ reports: [ScanReport], limit: Int = 10_000) -> ScanReport {
        var result = ScanReport(), identities = Set<String>()
        for report in reports {
            result.excluded += report.excluded; result.visited += report.visited; result.truncated = result.truncated || report.truncated
            for candidate in report.candidates {
                var info = stat()
                guard lstat(candidate.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { result.excluded += 1; continue }
                let key = "\(info.st_dev):\(info.st_ino)"
                guard identities.insert(key).inserted else { continue }
                if result.candidates.count >= min(10_000, max(1, limit)) { result.truncated = true; break }
                result.candidates.append(candidate)
            }
        }
        return result
    }
    /// Ranking uses measured metadata only. Modification age is not proof that a file is unused.
    public static func rank(_ report: ScanReport, now: Date = Date()) -> [SpaceRecommendation] {
        let sorted = report.candidates.sorted { lhs, rhs in
            let lhsDays = max(0, now.timeIntervalSince(lhs.modified)) / 86_400
            let rhsDays = max(0, now.timeIntervalSince(rhs.modified)) / 86_400
            let lhsScore = log2(Double(max(1, lhs.allocatedBytes))) + min(365, lhsDays) / 30
            let rhsScore = log2(Double(max(1, rhs.allocatedBytes))) + min(365, rhsDays) / 30
            return lhsScore == rhsScore ? lhs.url.path < rhs.url.path : lhsScore > rhsScore
        }
        return sorted.enumerated().map { index, candidate in
            let days = max(0, Int(now.timeIntervalSince(candidate.modified) / 86_400))
            return SpaceRecommendation(candidate: candidate, rank: index + 1,
                reason: "\(candidate.category) · last modified \(days) days ago · \(ByteCountFormatter.string(fromByteCount: candidate.allocatedBytes, countStyle: .file)) allocated estimate")
        }
    }
    public static func byCategory(_ report: ScanReport) -> [StorageBreakdown] { breakdown(report) { $0.category } }
    public static func byFolder(_ report: ScanReport, root: URL) -> [StorageBreakdown] {
        breakdown(report) { candidate in
            let relative = candidate.url.pathComponents.dropFirst(root.pathComponents.count)
            return relative.count > 1 ? String(relative.first!) : "Files in selected folder"
        }
    }
    private static func breakdown(_ report: ScanReport, group: (Candidate) -> String) -> [StorageBreakdown] {
        Dictionary(grouping: report.candidates, by: group).map { key, candidates in
            StorageBreakdown(id: key, logicalBytes: candidates.reduce(0) { $0 + $1.logicalBytes },
                             allocatedBytes: candidates.reduce(0) { $0 + $1.allocatedBytes }, files: candidates.count)
        }.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }
}

public enum CloudNestPreferences {
    public static func transferPolicy(from defaults: UserDefaults) throws -> TransferPolicy {
        guard let data = defaults.data(forKey: "transferPolicy") else { return TransferPolicy() }
        let policy = try JSONDecoder().decode(TransferPolicy.self, from: data); try policy.validate(); return policy
    }
    public static func recommendationRules(from defaults: UserDefaults) throws -> RecommendationRules {
        guard let data = defaults.data(forKey: "recommendationRules") else { return RecommendationRules() }
        return try JSONDecoder().decode(RecommendationRules.self, from: data)
    }
    public static func recommendationSchedule(from defaults: UserDefaults) throws -> RecommendationSchedule {
        guard let data = defaults.data(forKey: "recommendationSchedule") else { return RecommendationSchedule() }
        return try JSONDecoder().decode(RecommendationSchedule.self, from: data)
    }
    public static func save<T: Encodable>(_ value: T, key: String, to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}
