import Testing
import Foundation
@testable import StackCore

@Suite("BriefVersionDiff")
struct BriefVersionDiffTests {
    @Test("only changed fields appear, diffed from current to the version")
    func changedFields() {
        let v = Brief.Version(date: Date(), input: "old input", body: nil)
        let rows = BriefVersionDiff.rows(currentInput: "new input", currentBody: nil, version: v)
        #expect(rows.map(\.field) == [.input])
    }

    @Test("identical versions give no rows; a body only on one side still shows")
    func oneSidedBody() {
        let v = Brief.Version(date: Date(), input: "same", body: nil)
        #expect(BriefVersionDiff.rows(currentInput: "same", currentBody: nil, version: v).isEmpty)
        #expect(BriefVersionDiff.rows(currentInput: "same", currentBody: "edited", version: v).map(\.field) == [.body])
    }
}
