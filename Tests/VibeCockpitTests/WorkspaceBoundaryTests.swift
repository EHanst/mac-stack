import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("WorkspaceBoundary")
struct WorkspaceBoundaryTests {

    private func makeBoundary(root: URL) -> WorkspaceBoundary {
        let ctx = WorkspaceContext(
            root: root,
            workspaceID: WorkspaceID(rawValue: "test"),
            policy: .default
        )
        return WorkspaceBoundary(context: ctx)
    }

    @Test("allows file inside workspace")
    func allowsInsideFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws_test_allow")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let boundary = makeBoundary(root: tmp)
        try boundary.validateRead(tmp.appendingPathComponent("foo.swift"))
    }

    @Test("rejects path traversal via ..")
    func rejectsTraversal() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws_test_reject")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let boundary = makeBoundary(root: tmp)
        let escaped = tmp.appendingPathComponent("../outside.swift")
        #expect(throws: BoundaryError.self) {
            try boundary.validateRead(escaped)
        }
    }

    @Test("rejects symlink escape")
    func rejectsSymlink() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws_symlink_test")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let link = tmp.appendingPathComponent("escape.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let boundary = makeBoundary(root: tmp)
        #expect(throws: BoundaryError.self) {
            try boundary.validateRead(link)
        }
    }

    @Test("rejects disallowed command prefix")
    func rejectsDisallowedCommand() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let boundary = makeBoundary(root: tmp)
        #expect(throws: BoundaryError.self) {
            try boundary.validateExecution("rm -rf /")
        }
    }

    @Test("allows allowed command prefix")
    func allowsSwiftBuild() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let boundary = makeBoundary(root: tmp)
        try boundary.validateExecution("swift build --configuration release")
    }
}
