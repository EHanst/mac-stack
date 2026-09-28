import Testing
import Foundation
import MCP
@testable import VibeCockpitCore

@Suite("MCPService")
struct MCPServiceTests {

    // MARK: - Helpers

    private func makeRuntime() throws -> ToolRuntime {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let ctx = WorkspaceContext(
            root: workspaceURL,
            workspaceID: WorkspaceID(rawValue: "test"),
            policy: .default
        )
        let boundary = WorkspaceBoundary(context: ctx)
        let runner = XPCBuildRunner()
        let store = VectorStore(dbURL: workspaceURL.appendingPathComponent("index.db"))
        let registry = ModelRegistry()
        let pipeline = IndexingPipeline(store: store, registry: registry)
        let gitManager = GitSnapshotManager(workspaceURL: workspaceURL)
        return ToolRuntime(boundary: boundary, buildRunner: runner,
                           gitManager: gitManager, pipeline: pipeline)
    }

    @Test("isRunning reflects start/stop state")
    func startStopState() async throws {
        let runtime = try makeRuntime()
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString)")
        let gitMgr = GitSnapshotManager(workspaceURL: workspaceURL)
        let store = VectorStore(dbURL: workspaceURL.appendingPathComponent("index.db"))
        let pipeline = IndexingPipeline(store: store, registry: ModelRegistry())

        let service = MCPService(runtime: runtime, pipeline: pipeline, gitManager: gitMgr)
        #expect(await service.isRunning == false)

        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mcp-\(UUID().uuidString).sock").path
        try await service.start(socketPath: socketPath)
        #expect(await service.isRunning == true)

        await service.stop()
        #expect(await service.isRunning == false)

        // Socket file must be cleaned up
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("start is idempotent")
    func startIdempotent() async throws {
        let runtime = try makeRuntime()
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString)")
        let gitMgr = GitSnapshotManager(workspaceURL: workspaceURL)
        let store = VectorStore(dbURL: workspaceURL.appendingPathComponent("index.db"))
        let pipeline = IndexingPipeline(store: store, registry: ModelRegistry())
        let service = MCPService(runtime: runtime, pipeline: pipeline, gitManager: gitMgr)
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mcp-\(UUID().uuidString).sock").path

        try await service.start(socketPath: socketPath)
        try await service.start(socketPath: socketPath) // second call is no-op
        #expect(await service.isRunning == true)
        await service.stop()
    }
}
