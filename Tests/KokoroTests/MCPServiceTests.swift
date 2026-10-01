import Testing
import Foundation
import MCP
import Logging
@testable import KokoroCore
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
        let service = MCPService(host: MCPToolHost())
        await #expect(service.isRunning == false)
    }

    @Test("isRunning becomes true after startWithTransport")
    func runningAfterStart() async throws {
        let service = MCPService(host: MCPToolHost())
        try await service.startWithTransport(MockTransportForTests())
        await #expect(service.isRunning == true)
        await service.stop()
    }
}
