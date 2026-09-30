import Testing
import Foundation
@testable import StackCore

@Suite("BriefVersionDiff")
struct BriefVersionDiffTests {
    private func sections(goal: String, constraints: String = "") -> [BriefSection] {
        [BriefSection(kind: .goal, text: goal), BriefSection(kind: .constraints, text: constraints)]
    }

    @Test("only changed sections appear, diffed from current to the version")
    func changedOnly() {
        let v = Brief.Version(date: Date(), sections: sections(goal: "old goal", constraints: "same"))
        let rows = BriefVersionDiff.rows(current: sections(goal: "new goal", constraints: "same"), version: v)
        #expect(rows.map(\.kind) == [.goal])
        #expect(rows[0].segments.contains { $0.kind == .removed && $0.text.contains("new") })
        #expect(rows[0].segments.contains { $0.kind == .added && $0.text.contains("old") })
    }

    @Test("identical versions give no rows; a section only on one side still shows")
    func identicalAndMissing() {
        let s = sections(goal: "x")
        #expect(BriefVersionDiff.rows(current: s, version: .init(date: Date(), sections: s)).isEmpty)
        let v = Brief.Version(date: Date(), sections: [BriefSection(kind: .examples, text: "e.g. y")])
        let rows = BriefVersionDiff.rows(current: s, version: v)
        #expect(rows.map(\.kind) == [.goal, .examples])
    }
}
