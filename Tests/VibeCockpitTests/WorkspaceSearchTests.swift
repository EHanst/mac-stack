import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore

@Suite("WorkspaceSearch")
struct WorkspaceSearchTests {
    private func hit(_ path: String, _ score: Double) -> SearchResult {
        SearchResult(chunkID: UUID(), filePath: path, declarationKind: "func", content: path, score: score, rank: 1)
    }

    @Test("results from every project are merged best first and capped")
    func merges() async {
        let search = WorkspaceSearch()
        await search.register(id: "a") { _ in [self.hit("/a/1", 0.2), self.hit("/a/2", 0.9)] }
        await search.register(id: "b") { _ in [self.hit("/b/1", 0.5)] }
        let out = await search.search("q", limit: 2)
        #expect(out.map(\.filePath) == ["/a/2", "/b/1"])
    }

    @Test("a project that fails does not hide the others, and removed projects stop answering")
    func failuresAndRemoval() async {
        struct Boom: Error {}
        let search = WorkspaceSearch()
        await search.register(id: "bad") { _ in throw Boom() }
        await search.register(id: "ok") { _ in [self.hit("/ok/1", 1)] }
        #expect(await search.search("q", limit: 5).count == 1)
        await search.unregister(id: "ok")
        #expect(await search.search("q", limit: 5).isEmpty)
    }
}
