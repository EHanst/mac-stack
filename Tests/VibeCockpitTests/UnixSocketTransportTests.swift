import Testing
import Foundation
import Darwin
@testable import VibeCockpitCore

@Suite("UnixSocketTransport")
struct UnixSocketTransportTests {

    private func tempSocketPath() -> String {
        "/tmp/test-vibecockpit-\(UUID().uuidString).sock"
    }

    @Test("connect creates socket file and disconnect removes it")
    func connectDisconnect() async throws {
        let path = tempSocketPath()
        let transport = UnixSocketTransport(socketPath: path)
        try await transport.connect()
        #expect(FileManager.default.fileExists(atPath: path))
        await transport.disconnect()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("connect removes stale socket file and succeeds")
    func connectRemovesStaleSocket() async throws {
        let path = tempSocketPath()
        FileManager.default.createFile(atPath: path, contents: nil)
        let transport = UnixSocketTransport(socketPath: path)
        try await transport.connect()
        await transport.disconnect()
    }

    @Test("send appends newline delimiter that client reads")
    func sendAppendNewline() async throws {
        let path = tempSocketPath()
        let server = UnixSocketTransport(socketPath: path)
        try await server.connect()

        let clientFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(clientFD) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.withCString { src in _ = memcpy(dst.baseAddress!, src, min(strlen(src) + 1, dst.count)) }
        }
        let rc = withUnsafePointer(to: addr) {
            Darwin.connect(clientFD, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                           socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        #expect(rc == 0)

        try await Task.sleep(for: .milliseconds(50))

        let message = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        try await server.send(message)

        var buf = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(clientFD, &buf, buf.count)
        #expect(n > 0)
        let received = Data(buf[..<n])
        #expect(received.last == 0x0A)
        #expect(received.dropLast() == message)
        await server.disconnect()
    }
}
