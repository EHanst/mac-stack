# Embedded MCP Server Design

**Date:** 2026-09-28  
**Status:** Approved for implementation

---

## Goal

Remove the `VibeCockpitMCPServer` standalone executable. Embed the MCP server inside the VibeCockpit macOS app so it starts automatically at launch, shares the app's live service objects (index, git manager, runtime), and accepts connections from external MCP clients over a Unix domain socket.

---

## Problem

The current architecture runs the MCP server as a separate process (`VibeCockpitMCPServer`). This means:

- The server has its own copy of the index and git state, independent of the UI.
- Two processes must be kept alive and configured separately.
- Tool calls made through the MCP server do not reflect what the UI shows and vice versa.

---

## Solution: Unix Domain Socket Transport

The app process opens a Unix domain socket at `~/.vibecockpit/mcp.sock` during startup. External MCP clients (Claude Desktop, other agents) connect to this socket. Because the server runs inside the app process, every tool call shares the exact same `ToolRuntime`, `IndexingPipeline`, `GitSnapshotManager`, and `VectorStore` that the UI is using.

MCP clients use `socat` as a shim to present the socket as stdin/stdout to their MCP host:

```json
{
  "mcpServers": {
    "vibecockpit": {
      "command": "socat",
      "args": ["UNIX-CONNECT:/Users/<username>/.vibecockpit/mcp.sock", "-"]
    }
  }
}
```

---

## Components

### 1. `UnixSocketTransport` (`Sources/VibeCockpit/MCP/UnixSocketTransport.swift`)

An `actor` conforming to the MCP SDK's `Transport` protocol. Uses POSIX `socket(2)` / `bind` / `listen` / `accept` directly (avoids `NWListener` Unix socket availability gaps on macOS 26). Accepts **one client connection at a time** — when a new client connects, the previous connection is closed.

**Framing:** newline-delimited UTF-8 JSON, identical to the MCP stdio transport. Each JSON-RPC message is one line terminated by `\n`.

**Interface:**

```swift
public actor UnixSocketTransport: Transport {
    public init(socketPath: String, logger: Logger = .init(label: "mcp.unix"))
    // Transport conformance: connect(), disconnect(), send(_:), receive()
}
```

`connect()` creates the socket file, binds, and listens. If the socket file already exists (e.g. prior crash), it is removed and recreated. `receive()` returns an `AsyncThrowingStream<Data, Error>` that yields one complete JSON line per element, blocking on `accept()` between clients. `disconnect()` closes the listening file descriptor and removes the socket file.

**Error handling:** Socket errors on an active connection are logged and the connection is closed; the server re-enters the accept loop automatically.

### 2. `MCPService` (`Sources/VibeCockpit/MCP/MCPService.swift`)

An `actor` that owns the MCP `Server` instance and the tool list. Constructed with live service references from `AppServices`.

```swift
public actor MCPService {
    public init(
        runtime: ToolRuntime,
        pipeline: IndexingPipeline,
        gitManager: GitSnapshotManager
    )
    public func start(socketPath: String) async throws
    public func stop() async
    public var isRunning: Bool { get }
}
```

`start()` builds the tool list (same seven tools currently in `MCPServerMain`), registers MCP method handlers, constructs `UnixSocketTransport`, and calls `server.start(transport:)` on a detached `Task`. `stop()` cancels that task and calls `transport.disconnect()`.

The seven tool structs (`SearchCodeTool`, `RuntimeIndexWorkspaceTool`, `RuntimeFileReaderTool`, `RuntimeFileWriterTool`, `RuntimeRunBuildTool`, `SnapshotCreateTool`, `SnapshotDiffTool`) move from `Sources/VibeCockpitMCPServer/MCPServerMain.swift` into `Sources/VibeCockpit/MCP/MCPService.swift`. No behavioral changes to the tools themselves.

### 3. `AppServices` (modified)

Gains a `private var mcpService: MCPService?` and a `private var buildRunner: XPCBuildRunner` (promoting what was local in `startup()`). After service startup completes, `startup()` constructs `ToolRuntime` from the app's own services, builds `MCPService`, and calls `start(socketPath:)`.

Socket path: `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibecockpit/mcp.sock").path`

`MCPService.stop()` is called from a `deinit` Task.

### 4. `Package.swift` (modified)

The `VibeCockpitMCPServer` executable target and its path entry are removed. No new dependencies needed — `MCP` is already in `VibeCockpitCore`.

### 5. `project.yml` + `VibeCockpit.xcodeproj` (modified)

The `VibeCockpitMCPServer` target is removed. The main `VibeCockpit` app target gains the new `Sources/VibeCockpit/MCP/` source files automatically (they're already under `Sources/VibeCockpit/`).

### 6. `Sources/VibeCockpitMCPServer/` (deleted)

Entire directory removed after migration.

---

## Data Flow

```
Claude Desktop
    └─ socat UNIX-CONNECT:~/.vibecockpit/mcp.sock
           │
           ▼
  UnixSocketTransport  (inside app process)
           │  newline-delimited JSON-RPC
           ▼
     MCPService.server  (MCP SDK Server)
           │  dispatches tool calls
           ▼
     ToolRuntime ◄──── same instance the UI is using
     IndexingPipeline ◄────
     GitSnapshotManager ◄────
```

---

## Lifecycle

1. App launches → `AppServices.startup()` runs.
2. Registry discovered, providers health-checked, git manager opened.
3. `MCPService.start()` binds the socket, begins listening; path logged at info level.
4. Claude Desktop connects via socat → tools available immediately, sharing live state.
5. App quits → `MCPService.stop()` closes the socket and removes the `.sock` file.
6. If the app crashes, the stale socket file is silently removed on the next launch.

---

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| Socket file exists at startup | Remove and recreate silently |
| `bind` fails (bad path, permissions) | Log error; `isRunning` stays false; app continues without MCP |
| Client disconnects mid-call | In-flight tool `Task` is cancelled; server re-enters accept loop |
| Tool call throws | MCP SDK returns JSON-RPC error response; connection stays open |
| App crashes with active socket | Stale file removed on next `connect()` |

---

## Testing

**`MCPServiceTests.swift`** (unit):
- Construct `MCPService` with stub/mock services.
- Use `InMemoryTransport` (already in MCP SDK) to drive `server.start(transport:)`.
- Assert `tools/list` returns the expected seven tool names.
- Assert `tools/call search_code` with a valid query returns a non-error content response.

**`UnixSocketTransportTests.swift`** (integration):
- Start `UnixSocketTransport` on a temp path (e.g. `/tmp/test-mcp-\(UUID()).sock`).
- Open a client `FileHandle` to the same path.
- Write a raw JSON-RPC `initialize` request; read and assert a valid response line.
- Close client, reconnect; assert server still responds (reconnect test).

---

## Migration Notes for Users

- Claude Desktop config must change from the old binary path to the `socat` command above.
- `socat` must be installed: `brew install socat`.
- The `VibeCockpitMCPServer` build scheme is gone; building `VibeCockpit` is sufficient.

---

## Out of Scope

- TLS or authentication (local socket; protected by macOS filesystem permissions).
- Multiple simultaneous client connections (one at a time is sufficient).
- HTTP/SSE transport (future work if remote access is needed).
