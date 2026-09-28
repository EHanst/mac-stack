import Foundation
import MCP
import os
#if canImport(Darwin)
import Darwin
#endif

/// POSIX Unix domain socket transport for the embedded MCP server.
/// Accepts one client at a time; a new connection replaces the previous one.
/// Framing: newline-delimited UTF-8 JSON, identical to StdioTransport.
public actor UnixSocketTransport: Transport {

    private let socketPath: String
    private let logger: Logger

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    public init(socketPath: String,
                logger: Logger = Logger(subsystem: "com.vibecockpit", category: "UnixSocketTransport")) {
        self.socketPath = socketPath
        self.logger = logger
    }

    // MARK: - Transport conformance

    public func connect() throws {
        // Remove stale socket file from a prior crash
        unlink(socketPath)

        // Create parent directory if needed
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.bindFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            socketPath.withCString { cStr in
                _ = strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self),
                            cStr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw TransportError.bindFailed(errno: errno)
        }

        guard listen(fd, 1) == 0 else {
            close(fd)
            throw TransportError.bindFailed(errno: errno)
        }

        listenFD = fd
        logger.info("MCP Unix socket listening at \(self.socketPath, privacy: .public)")
    }

    public func disconnect() {
        if clientFD >= 0 { close(clientFD); clientFD = -1 }
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
        continuation?.finish()
        continuation = nil
        logger.info("MCP Unix socket closed")
    }

    public func send(_ data: Data) async throws {
        guard clientFD >= 0 else { throw TransportError.notConnected }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        try payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < payload.count {
                let n = Darwin.write(clientFD, base.advanced(by: written), payload.count - written)
                if n <= 0 { throw TransportError.writeFailed(errno: errno) }
                written += n
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            self.continuation = cont
            Task.detached { [weak self] in
                await self?.acceptLoop(cont)
            }
        }
    }

    // MARK: - Accept loop

    private func acceptLoop(_ cont: AsyncThrowingStream<Data, Error>.Continuation) async {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if listenFD < 0 { break }  // disconnect() was called
                logger.error("accept() failed errno=\(errno)")
                continue
            }

            // Close previous client
            if clientFD >= 0 { close(clientFD) }
            clientFD = fd
            logger.debug("MCP client connected fd=\(fd)")

            await readLines(from: fd, into: cont)

            logger.debug("MCP client disconnected fd=\(fd)")
            if clientFD == fd { clientFD = -1 }
        }
    }

    private func readLines(from fd: Int32,
                           into cont: AsyncThrowingStream<Data, Error>.Continuation) async {
        var buffer = Data()
        let chunk = 4096
        var raw = [UInt8](repeating: 0, count: chunk)

        while true {
            let n = Darwin.read(fd, &raw, chunk)
            if n <= 0 { break }
            buffer.append(contentsOf: raw[0..<n])

            // Yield every complete newline-delimited JSON line
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                if !line.isEmpty {
                    cont.yield(Data(line))
                }
                buffer = buffer[buffer.index(after: nl)...]
            }

            if Task.isCancelled { break }
        }
    }

    // MARK: - Errors

    public enum TransportError: LocalizedError {
        case bindFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .bindFailed(let e):  "Unix socket bind failed: errno \(e)"
            case .writeFailed(let e): "Unix socket write failed: errno \(e)"
            case .notConnected:       "No connected client"
            }
        }
    }
}
