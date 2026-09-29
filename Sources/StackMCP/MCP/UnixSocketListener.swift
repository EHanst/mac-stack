import Darwin
import Foundation
import Logging
import MCP

/// One accepted connection on the MCP socket, as an MCP `Transport` (newline-delimited JSON).
public actor SocketConnectionTransport: Transport {

    public nonisolated let logger: Logger

    /// The file descriptor is closed exactly once, and never while a write is using it: a write
    /// that outlived the close would hit whatever unrelated file the OS reused the number for.
    /// `shutdown` wakes a blocked reader without ever touching a descriptor that was already closed.
    private final class Descriptor: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var open = true
        private var writers = 0
        private var closePending = false
        init(_ fd: Int32) { self.fd = fd }
        var isOpen: Bool { lock.withLock { open } }
        func shutdown() { lock.withLock { if open { Darwin.shutdown(fd, SHUT_RDWR) } } }
        func close() {
            lock.withLock {
                guard open else { return }
                open = false
                if writers == 0 { Darwin.close(fd) } else { closePending = true }
            }
        }
        /// Pins the descriptor for a write; false if it is already closed. Pair with `endWrite`.
        func beginWrite() -> Bool { lock.withLock { if open { writers += 1; return true } else { return false } } }
        func endWrite() {
            lock.withLock {
                writers -= 1
                if writers == 0, closePending { closePending = false; Darwin.close(fd) }
            }
        }
    }

    private let descriptor: Descriptor
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let writeQueue = DispatchQueue(label: "mcp.unix.conn.write", qos: .utility)
    private var started = false

    init(fd: Int32, logger: Logger? = nil) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        self.descriptor = Descriptor(fd)
        self.logger = logger ?? Logger(label: "mcp.transport.unix.conn", factory: { _ in SwiftLogNoOpLogHandler() })
        (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    }

    public func connect() async throws {
        guard !started else { return }
        started = true
        let descriptor = self.descriptor, continuation = self.continuation
        Thread.detachNewThread {
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(descriptor.fd, $0.baseAddress!, $0.count) }
                if n <= 0 { break }
                pending.append(contentsOf: chunk[..<n])
                while let idx = pending.firstIndex(of: 0x0A) {
                    let line = pending[..<idx]
                    if !line.isEmpty { continuation.yield(Data(line)) }
                    pending = Data(pending[pending.index(after: idx)...])
                }
            }
            continuation.finish()
            descriptor.close()
        }
    }

    public func disconnect() async {
        descriptor.shutdown()
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard descriptor.isOpen else { throw UnixSocketListener.ListenerError.notConnected }
        let payload = data + Data([0x0A])
        let descriptor = self.descriptor
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                guard descriptor.beginWrite() else { cont.resume(throwing: UnixSocketListener.ListenerError.notConnected); return }
                defer { descriptor.endWrite() }
                var offset = 0
                while offset < payload.count {
                    let n = payload.withUnsafeBytes { Darwin.write(descriptor.fd, $0.baseAddress! + offset, payload.count - offset) }
                    if n <= 0 { cont.resume(throwing: UnixSocketListener.ListenerError.notConnected); return }
                    offset += n
                }
                cont.resume()
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> { stream }
}

/// Listens on a Unix socket and hands every connection to `onConnection`. The socket file is
/// owner-only (0600): only the signed-in user's processes can connect.
public final class UnixSocketListener: @unchecked Sendable {

    public enum ListenerError: Error, Equatable {
        case pathTooLong
        case socketCreationFailed
        case bindFailed(Int32)
        case listenFailed(Int32)
        case notConnected
    }

    private let path: String
    private let onConnection: @Sendable (SocketConnectionTransport) -> Void
    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var stopped = false

    public init(path: String, onConnection: @escaping @Sendable (SocketConnectionTransport) -> Void) {
        self.path = path
        self.onConnection = onConnection
    }

    public func start() throws {
        try? FileManager.default.removeItem(atPath: path)     // stale file from a previous run
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ListenerError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.withCString { src in _ = memcpy(dst.baseAddress!, src, strlen(src) + 1) }
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socketCreationFailed }
        let bound = withUnsafePointer(to: addr) {
            Darwin.bind(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        guard bound == 0 else { let e = errno; Darwin.close(fd); throw ListenerError.bindFailed(e) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { let e = errno; Darwin.close(fd); throw ListenerError.listenFailed(e) }

        var pipeFDs: [Int32] = [-1, -1]
        _ = pipeFDs.withUnsafeMutableBufferPointer { Darwin.pipe($0.baseAddress!) }
        lock.withLock { serverFD = fd; wakeWrite = pipeFDs[1]; stopped = false }
        let wakeRead = pipeFDs[0]
        let onConnection = self.onConnection

        Thread.detachNewThread { [weak self] in
            while true {
                var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
                let rc = poll(&fds, 2, -1)
                if rc < 0 { if errno == EINTR { continue } else { break } }
                if fds[1].revents != 0 { break }                       // stop() woke us
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { if errno == EINTR || errno == ECONNABORTED { continue } else { break } }
                onConnection(SocketConnectionTransport(fd: client))
            }
            Darwin.close(wakeRead)
            self?.finishStop()
        }
    }

    public func stop() {
        let (w, isStopped): (Int32, Bool) = lock.withLock { let r = (wakeWrite, stopped); stopped = true; wakeWrite = -1; return r }
        guard !isStopped, w >= 0 else { return }
        try? FileManager.default.removeItem(atPath: path)   // now, so a restart can't lose its new file to us
        _ = Darwin.write(w, "x", 1)
        Darwin.close(w)
    }

    /// Runs on the accept thread once it has left its loop.
    private func finishStop() {
        let fd: Int32 = lock.withLock { let f = serverFD; serverFD = -1; return f }
        if fd >= 0 { Darwin.close(fd) }
    }
}
