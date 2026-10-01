import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore
@testable import StackMCP

@Suite("ToolRuntime")
struct ToolRuntimeTests {

    private func makeRuntime(root: URL) async throws -> ToolRuntime {
        let ctx = WorkspaceContext(root: root, workspaceID: WorkspaceID(rawValue: "rt"), policy: .default)
        let boundary = WorkspaceBoundary(context: ctx)
        let store = VectorStore(dbURL: root.appendingPathComponent(".vc/index.sqlite"))
        try await store.open()
        let registry = ModelRegistry()
        let pipeline = IndexingPipeline(store: store, registry: registry)
        try await pipeline.open()
        let gitManager = GitSnapshotManager(workspaceURL: root)
        let buildRunner = BuildRunner()
        return ToolRuntime(boundary: boundary, buildRunner: buildRunner,
                           gitManager: gitManager, pipeline: pipeline)
    }

    @Test("readFile returns content for file inside workspace")
    func readFileInside() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rt_read_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("hello.swift")
        try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
        let runtime = try await makeRuntime(root: tmp)
        let content = try await runtime.readFile(path: file, startLine: nil, endLine: nil)
        #expect(content.contains("let x = 1"))
    }

    @Test("readFile throws for path outside workspace")
    func readFileOutside() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rt_outside_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = try await makeRuntime(root: tmp)
        await #expect(throws: BoundaryError.self) {
            _ = try await runtime.readFile(
                path: URL(fileURLWithPath: "/etc/passwd"), startLine: nil, endLine: nil)
        }
    }

    @Test("cancel does not throw for unknown operation")
    func cancelUnknownNoop() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rt_cancel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = try await makeRuntime(root: tmp)
        await runtime.cancelOperation(OperationID(rawValue: UUID()))
    }
}
