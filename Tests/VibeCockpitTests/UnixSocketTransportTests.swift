import Testing
import Foundation
@testable import VibeCockpitCore

@Suite("UnixSocketTransport")
struct UnixSocketTransportTests {

    private func tempSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sock").path
    }

    @Test("bind, connect, send a line, receive it back")
    func roundTrip() async throws {
        let path = tempSocketPath()
        let transport = UnixSocketTransport(socketPath: path)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        // Open a client FileHandle
        let clientFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(clientFD >= 0)
        defer { Darwin.close(clientFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            path.withCString { cStr in
                _ = strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self),
                            cStr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            }
        }

        // Poll until the socket is ready (accept() takes a moment)
        var connected = false
        for _ in 0..<20 {
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 { connected = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(connected)

        // Write a JSON line from client side
        let payload = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}\n"
        let data = payload.data(using: .utf8)!
        let written = data.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress!, data.count) }
        #expect(written == data.count)

        // Read it back from the transport's receive stream
        let stream = await transport.receive()
        var iter = stream.makeAsyncIterator()
        let received = try await iter.next()
        #expect(received != nil)
        let text = String(data: received!, encoding: .utf8) ?? ""
        #expect(text.contains("ping"))
    }

    @Test("stale socket file is removed on connect()")
    func staleSocketRemoved() async throws {
        let path = tempSocketPath()
        // Create a stale file at the path
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        #expect(FileManager.default.fileExists(atPath: path))

        let transport = UnixSocketTransport(socketPath: path)
        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        // The socket should now exist as a live socket, not a regular file
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("socket file removed after disconnect()")
    func socketRemovedOnDisconnect() async throws {
        let path = tempSocketPath()
        let transport = UnixSocketTransport(socketPath: path)
        try await transport.connect()
        #expect(FileManager.default.fileExists(atPath: path))
        await transport.disconnect()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
