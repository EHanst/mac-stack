import Darwin
import Foundation

// vibe-mcp — connects an MCP client that speaks stdio (Claude Desktop, Cursor, …) to the
// VibeCockpit app's local MCP socket. Replaces `socat - UNIX-CONNECT:~/.vibecockpit/mcp.sock`.
//
//   vibe-mcp [--socket PATH]      (default: ~/.vibecockpit/mcp.sock, or $VIBECOCKPIT_MCP_SOCKET)
//
// stdin → socket, socket → stdout, until either side closes. Exit codes: 0 done, 2 usage,
// 69 VibeCockpit isn't running.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("vibe-mcp: \(message)\n".utf8))
    exit(code)
}

var path = ProcessInfo.processInfo.environment["VIBECOCKPIT_MCP_SOCKET"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibecockpit/mcp.sock").path
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--socket": guard let v = args.next() else { fail("--socket needs a path", code: 2) }; path = v
    case "-h", "--help": print("usage: vibe-mcp [--socket PATH]"); exit(0)
    default: fail("unknown argument \(a)", code: 2)
    }
}

signal(SIGPIPE, SIG_IGN)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { fail("socket path is too long", code: 2) }
withUnsafeMutableBytes(of: &addr.sun_path) { dst in path.withCString { src in _ = memcpy(dst.baseAddress!, src, strlen(src) + 1) } }
let connected = withUnsafePointer(to: addr) {
    connect(fd, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_un>.size))
}
guard connected == 0 else {
    fail("can't reach VibeCockpit at \(path). Open the VibeCockpit app first (it runs in the menu bar).", code: 69)
}

/// Copies `from` to `to` until end of input or a write fails.
func pump(from: Int32, to: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = buffer.withUnsafeMutableBufferPointer { read(from, $0.baseAddress!, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return }
        var offset = 0
        while offset < n {
            let w = buffer.withUnsafeBufferPointer { write(to, $0.baseAddress! + offset, n - offset) }
            if w < 0 && errno == EINTR { continue }
            if w <= 0 { return }
            offset += w
        }
    }
}

// socket → stdout on a helper thread; stdin → socket here. Either side ending ends the process.
let done = DispatchSemaphore(value: 0)
Thread.detachNewThread { pump(from: fd, to: STDOUT_FILENO); done.signal() }
Thread.detachNewThread { pump(from: STDIN_FILENO, to: fd); shutdown(fd, SHUT_WR) }   // stdin closed: let the server finish replying
done.wait()
exit(0)
