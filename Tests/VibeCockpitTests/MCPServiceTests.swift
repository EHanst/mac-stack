import Testing
import Foundation
import MCP
import Logging
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

actor MockTransportForTests: Transport {
    nonisolated let logger = Logger(label: "mock", factory: { _ in SwiftLogNoOpLogHandler() })
    private(set) var isConnected = false
    private(set) var sentData: [Data] = []
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func connect() async throws { isConnected = true }
    func disconnect() async {
        isConnected = false
        continuation?.finish()
    }
    func send(_ data: Data) async throws { sentData.append(data) }
    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { self.continuation = $0 }
    }
    func inject(_ data: Data) { continuation?.yield(data) }
}

@Suite("MCPService")
struct MCPServiceTests {

    @Test("isRunning is false before start")
    func notRunningBeforeStart() async {
        let service = MCPService(
            runtime: makeStubRuntime(),
            pipeline: makeStubPipeline(),
            gitManager: GitSnapshotManager(workspaceURL: URL(fileURLWithPath: "/tmp"))
        )
        await #expect(service.isRunning == false)
    }

    @Test("isRunning becomes true after startWithTransport")
    func runningAfterStart() async throws {
        let transport = MockTransportForTests()
        let service = MCPService(
            runtime: makeStubRuntime(),
            pipeline: makeStubPipeline(),
            gitManager: GitSnapshotManager(workspaceURL: URL(fileURLWithPath: "/tmp"))
        )
        try await service.startWithTransport(transport)
        await #expect(service.isRunning == true)
        await service.stop()
    }
}

private func makeStubPipeline() -> IndexingPipeline {
    IndexingPipeline(
        store: VectorStore(dbURL: URL(fileURLWithPath: "/tmp/test-pipeline.db")),
        registry: ModelRegistry()
    )
}

private func makeStubRuntime() -> ToolRuntime {
    let ctx = WorkspaceContext(
        root: URL(fileURLWithPath: "/tmp"),
        workspaceID: WorkspaceID(rawValue: "test"),
        policy: .default
    )
    let boundary = WorkspaceBoundary(context: ctx)
    return ToolRuntime(
        boundary: boundary,
        buildRunner: XPCBuildRunner(),
        gitManager: GitSnapshotManager(workspaceURL: URL(fileURLWithPath: "/tmp")),
        pipeline: makeStubPipeline()
    )
}
