import Testing
import Foundation
@testable import StackCore

@Suite("RankFusion")
struct RankFusionTests {
    @Test("an id in both lists outranks ids in one")
    func fusesLists() {
        let out = RankFusion.fuse([["a", "b", "c"], ["c", "d"]])
        #expect(out.first?.id == "c")
        #expect(Set(out.map(\.id)) == ["a", "b", "c", "d"])
    }

    @Test("ties break by id so the order is deterministic")
    func deterministic() {
        let out = RankFusion.fuse([["b"], ["a"]])
        #expect(out.map(\.id) == ["a", "b"])
    }

    @Test("empty input gives empty output")
    func empty() {
        #expect(RankFusion.fuse([]).isEmpty)
        #expect(RankFusion.fuse([[], []]).isEmpty)
    }
}
