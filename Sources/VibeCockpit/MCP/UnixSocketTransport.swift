import Darwin
import Foundation
import Logging
import MCP

public actor UnixSocketTransport: Transport {

    public nonisolated let logger: Logger
    private let socketPath: String

    // nonisolated(unsafe): accessed from actor (send/disconnect) and the DispatchQueue accept loop.
    // Safe because MCP is sequential: send() is only called after a message arrives on clientFD,
    // so clientFD is stable for the duration of each request-response pair.
    nonisolated(unsafe) private var serverFD: Int32 = -1
    nonisolated(unsafe) private var clientFD: Int32 = -1

    private let messageStream: AsyncThrowingStream<Data, Error>
    private let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let ioQueue = DispatchQueue(label: "mcp.unix.io", qos: .utility)

    public enum TransportError: Error {
        case socketCreationFailed
        case bindFailed(Int32)
        case listenFailed(Int32)
        case notConnected
    }

    public init(socketPath: String, logger: Logger? = nil) {
        self.socketPath = socketPath
        self.logger = logger ?? Logger(label: "mcp.transport.unix",
                                       factory: { _ in SwiftLogNoOpLogHandler() })
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { cont = $0 }
        self.messageContinuation = cont
    }

    public func connect() async throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socketCreationFailed }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            socketPath.withCString { src in
                _ = memcpy(dst.baseAddress!, src, min(strlen(src) + 1, dst.count))
            }
        }
        let bindRC = withUnsafePointer(to: addr) {
            Darwin.bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                        socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        guard bindRC == 0 else { throw TransportError.bindFailed(errno) }
        guard Darwin.listen(fd, 1) == 0 else { throw TransportError.listenFailed(errno) }

        logger.info("MCP server listening", metadata: ["path": .string(socketPath)])
        startAcceptLoop()
    }

    public func disconnect() async {
        let cfd = clientFD
        let sfd = serverFD
        if cfd >= 0 { Darwin.close(cfd); clientFD = -1 }
        if sfd >= 0 { Darwin.close(sfd); serverFD = -1 }
        try? FileManager.default.removeItem(atPath: socketPath)
        messageContinuation.finish()
        logger.info("MCP server stopped")
    }

    public func send(_ data: Data) async throws {
        let fd = clientFD
        guard fd >= 0 else { throw TransportError.notConnected }
        var payload = data
        payload.append(0x0A) // newline delimiter
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                let result = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                if result == payload.count {
                    cont.resume()
                } else {
                    cont.resume(throwing: TransportError.notConnected)
                }
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        messageStream
    }

    // MARK: - Private

    private func startAcceptLoop() {
        let sfd = serverFD
        let cont = messageContinuation
        let log = logger
        ioQueue.async { [weak self] in
            while true {
                let cfd = Darwin.accept(sfd, nil, nil)
                guard cfd >= 0 else { break }
                self?.clientFD = cfd
                log.info("MCP client connected")
                Self.readLines(fd: cfd, into: cont, logger: log)
                Darwin.close(cfd)
                self?.clientFD = -1
                log.info("MCP client disconnected, accepting next connection")
            }
            cont.finish()
        }
    }

    private static func readLines(
        fd: Int32,
        into cont: AsyncThrowingStream<Data, Error>.Continuation,
        logger: Logger
    ) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            pending.append(contentsOf: chunk[..<n])
            while let idx = pending.firstIndex(of: 0x0A) {
                let line = pending[..<idx]
                if !line.isEmpty { cont.yield(Data(line)) }
                pending = Data(pending[pending.index(after: idx)...])
            }
        }
    }
}
