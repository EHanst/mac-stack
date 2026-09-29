import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("GitSnapshotManager")
struct GitSnapshotManagerTests {

    @Test("shortOID returns first 7 characters of oid")
    func shortOIDProperty() {
        let ref = SnapshotRef(id: UUID(),
                              oid: "abc1234567890def1234567890abc1234567890ab",
                              message: "test",
                              createdAt: Date(),
                              branchName: "refs/test")
        #expect(ref.shortOID == "abc1234")
    }

    @Test("shortOID on short oid returns full string")
    func shortOIDOnShortString() {
        let ref = SnapshotRef(id: UUID(),
                              oid: "abc12",
                              message: "test",
                              createdAt: Date(),
                              branchName: "refs/test")
        #expect(ref.shortOID == "abc12")
    }
}
