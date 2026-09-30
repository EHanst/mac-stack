import Foundation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Where a brief's context comes from: the registered project folders, the code index, and git.
/// Closures, so tests can supply fakes and the app wires the real pipeline.
public struct BriefContextSource: Sendable {
    public var roots: @Sendable () async -> [URL]
    public var search: @Sendable (String) async throws -> [SearchResult]
    public var workingDiff: @Sendable (URL) async throws -> String

    public init(roots: @escaping @Sendable () async -> [URL],
                search: @escaping @Sendable (String) async throws -> [SearchResult],
                workingDiff: @escaping @Sendable (URL) async throws -> String) {
        self.roots = roots; self.search = search; self.workingDiff = workingDiff
    }
}

public enum WorkspaceSearchError: LocalizedError, Equatable {
    case allFailed
    public var errorDescription: String? { "Search failed. The project's index may still be starting; try again in a moment." }
}

/// Each project has its own code index; this asks all of them and merges the answers.
public actor WorkspaceSearch {
    public typealias Searcher = @Sendable (String) async throws -> [SearchResult]
    private var searchers: [String: Searcher] = [:]

    public init() {}

    public func register(id: String, _ searcher: @escaping Searcher) { searchers[id] = searcher }
    public func unregister(id: String) { searchers[id] = nil }

    public func searchOrThrow(_ query: String, limit: Int) async throws -> [SearchResult] {
        let current = Array(searchers.values)
        guard !current.isEmpty else { return [] }
        var all: [SearchResult] = []
        var failures = 0
        for searcher in current {
            do { all += try await searcher(query) } catch { failures += 1 }
        }
        if failures == current.count { throw WorkspaceSearchError.allFailed }
        return Array(all.sorted { $0.score > $1.score }.prefix(limit))
    }

    public func search(_ query: String, limit: Int) async -> [SearchResult] {
        var all: [SearchResult] = []
        for searcher in searchers.values {
            if let results = try? await searcher(query) { all += results }
        }
        return Array(all.sorted { $0.score > $1.score }.prefix(limit))
    }
}
