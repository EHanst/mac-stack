import Darwin
import Foundation
import Logging
import MCP
#if SWIFT_PACKAGE
import StackCore
#endif

public actor UnixSocketTransport: Transport {

    public nonisolated let logger: Logger
    private let socketPath: String

    // nonisolated(unsafe): accessed from actor (send/disconnect) and the DispatchQueue accept loop.
    // Safe because MCP is sequential: send() is only called after a message arrives on clientFD,
    // so clientFD is stable for the duration of each request-response pair.
    nonisolated(unsafe) private var serverFD: Int32 = -1
    nonisolated(unsafe) private var clientFD: Int32 = -1
    // stop flag + wakeup pipe to interrupt blocking accept() on disconnect
    nonisolated(unsafe) private var stopped: Bool = false
    nonisolated(unsafe) private var wakePipeRead: Int32 = -1
    nonisolated(unsafe) private var wakePipeWrite: Int32 = -1

    private let messageStream: AsyncThrowingStream<Data, Error>
    private let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation
    // ioQueue runs the accept/read loop (long-lived, blocking).
    // writeQueue is separate so send() is never blocked by the accept loop.
    private let ioQueue = DispatchQueue(label: "mcp.unix.io", qos: .utility)
    private let writeQueue = DispatchQueue(label: "mcp.unix.write", qos: .utility)

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

        var pipeFDs: [Int32] = [-1, -1]
        pipeFDs.withUnsafeMutableBufferPointer { _ = Darwin.pipe($0.baseAddress!) }
        wakePipeRead = pipeFDs[0]
        wakePipeWrite = pipeFDs[1]

        logger.info("MCP server listening", metadata: ["path": .string(socketPath)])
        startAcceptLoop()
    }

    public func disconnect() async {
        stopped = true
        let cfd = clientFD
        let sfd = serverFD
        let wpw = wakePipeWrite
        let wpr = wakePipeRead
        if cfd >= 0 { Darwin.close(cfd); clientFD = -1 }
        // Write to the wake pipe to unblock select() in the accept loop.
        if wpw >= 0 { _ = Darwin.write(wpw, "x", 1); Darwin.close(wpw); wakePipeWrite = -1 }
        if sfd >= 0 { Darwin.close(sfd); serverFD = -1 }
        if wpr >= 0 { Darwin.close(wpr); wakePipeRead = -1 }
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
            writeQueue.async {
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
        let pipeRead = wakePipeRead
        let cont = messageContinuation
        let log = logger
        ioQueue.async { [weak self] in
            while !(self?.stopped ?? true) {
                // Use select() to wait on either a new connection or the wake pipe.
                var rfds = fd_set()
                // Zero-init and set bits manually (fd_set macros aren't available in Swift).
                withUnsafeMutableBytes(of: &rfds) { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) }
                let maxfd = max(sfd, pipeRead)
                let wordIdx = Int(sfd) / 32
                let bitIdx  = Int(sfd) % 32
                withUnsafeMutableBytes(of: &rfds) { ptr in
                    let words = ptr.bindMemory(to: UInt32.self)
                    words[wordIdx] |= (1 << bitIdx)
                    if pipeRead >= 0 {
                        let pw = Int(pipeRead) / 32
                        let pb = Int(pipeRead) % 32
                        words[pw] |= (1 << pb)
                    }
                }
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                let rc = Darwin.select(maxfd + 1, &rfds, nil, nil, &tv)
                if rc <= 0 { continue } // timeout or signal, re-check stopped flag
                // Check wake pipe first
                if pipeRead >= 0 {
                    let pw = Int(pipeRead) / 32; let pb = Int(pipeRead) % 32
                    let isSet = withUnsafeBytes(of: rfds) { ptr -> Bool in
                        let words = ptr.bindMemory(to: UInt32.self)
                        return words[pw] & (1 << pb) != 0
                    }
                    if isSet { break }
                }
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
