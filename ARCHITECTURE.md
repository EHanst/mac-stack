# KOKORO: NATIVE SYSTEMS ARCHITECTURE

> **Product (2026-09-30):** Kokoro is a prompt sidecar for frontier models (Claude Code, Cursor, ChatGPT). It turns a developer's rough intent into a Brief, a prompt a frontier model can act on the first time, using a small local model on Apple Silicon. It is not a chat app or an IDE. The workspace tools (`write_file`, `run_build`, `snapshot_create`, `snapshot_diff`) remain only as scoped MCP tools for other clients; the app has no agent loop. Persisted names keep the old spelling (`VibeCockpit` support folder, `com.vibecockpit.app`, `vibecockpit` MCP key, `.vibe/` project folders). See `docs/superpowers/specs/2026-09-29-prompt-sidecar-design.md` and `CLAUDE.md`.

These are the architecture rules for native macOS work on this repo. Everything runs in-process on Apple Silicon.

---

### 1. ABSOLUTE ARCHITECTURAL CONSTRAINTS (ZERO-TOLERANCE RULES)

You must strictly reject and never propose, generate, or rely upon any of the following:
* **NO Interpreted Scripting Runtimes:** Strictly zero Python (`python3`, `pip`, `venv`), Node.js (`npm`, `npx`, `node`), Bun, or Ruby.
* **NO Web Shells or Non-Native GUIs:** Strictly zero Electron, Chromium, Tauri, or Flutter wrappers. The entire UI must be written in native SwiftUI and AppKit.
* **NO External Server Daemons or Network Serialization *for internal calls*:** Strictly zero standalone servers (`mlx-lm.server`, FastAPI, Express) and no HTTP between our own components. Inside the app, inference and tool calls stay in-process via direct memory buffers and Swift structured concurrency. **Exception (2026-09-28, see `docs/plans/2026-09-28-next-phase-plan.md`):** the app itself may expose an *opt-in* OpenAI-compatible API and MCP Streamable HTTP endpoint for *other* applications, bound to `127.0.0.1` only, off by default, authenticated with per-client bearer tokens, in the same process as the model (never a second process holding weights).
* **NO Containerization or Heavy Hypervisors for Daily Loops:** Strictly zero Docker, Podman, or persistent VM daemons. Sandboxing must be handled via the Darwin kernel.
* **NO Shell-Piped Git Commands:** Strictly zero calls to `Process("/usr/bin/git")` for snapshots, diffs, or commits.
* **NO Naive Text Chunking:** Strictly zero fixed-character or arbitrary token splitting for code retrieval.

*Violation Protocol:* If a user request nudges toward or explicitly requests Python scripts, Docker containers, Node MCP servers, or HTTP-based orchestration *between our own components*, you must explicitly decline the middleware approach and provide the equivalent native Swift/C in-process primitive.

---

### 2. CANONICAL TECHNICAL STACK & PRIMITIVES

Every line of code and architectural design you emit must map directly to these authorized components:

| Subsystem | Canonical Primitive & Standard |
| :--- | :--- |
| **Language & Concurrency** | Swift 5.10 / Swift 6. Strict Concurrency (`Complete`), Swift Actors, `Sendable` types, Structured Task Groups, and `AsyncThrowingStream`. |
| **Local Inference** | `mlx-swift` and `mlx-swift-lm` integrated directly via Swift Package Manager (SPM). Metal compute shaders compiled into `Contents/Resources/default.metallib`. |
| **Memory Management** | Zero-copy access across Apple's Unified Memory Architecture (UMA). Pointers to model weights and KV caches stay resident in unified memory. Active memory footprint must remain under **14.7 GB**. |
| **Tool Execution Bus** | In-process Swift protocols conforming to the `modelcontextprotocol/swift-sdk`. Strong types with static JSON-schema generation. No standard I/O pipes for internal tools. |
| **Subprocess Execution** | The MCP `run_build` tool runs a command through `BuildRunner` (`/bin/zsh -c`, in the workspace), gated by `ClientScope` `.toolsExec`. There is no seatbelt sandbox. |
| **Version Control & Diffs** | Direct C-linking to `libgit2` through a Clang `module.modulemap`. In-memory commit trees, atomic snapshot references, and sub-5ms unified diff generation. |
| **AST Analysis & Code RAG** | Apple's `SwiftSyntax` / `SwiftParser` (for Swift) and Tree-sitter C bindings (for polyglot parsing). Code chunks split strictly along declaration boundaries (`struct`, `class`, `func`, `protocol`). |
| **Vector Storage & Retrieval** | In-process SQLite database (`~/Library/Application Support/VibeCockpit/index.db`) linking `sqlite-vec` (C module) for KNN dense cosine vector search, SQLite `FTS5` for BM25 keyword matching, and Reciprocal Rank Fusion (RRF, $k=60$) for hybrid rank merging. |
| **UI** | Pure SwiftUI and AppKit: a `NavigationSplitView` with Briefs, Library, Models and Settings, backed by `@Observable` models. |
| **Signing & OS Compliance** | Hardened Runtime enabled with Developer ID signing (`com.apple.security.cs.allow-jit`, `com.apple.security.cs.disable-executable-page-protection`). Must pass `notarytool` verification. |

---

### 3. CODE GENERATION STANDARDS

When generating implementations:
1. **Completeness:** Never emit placeholder comments (`// TODO: implement later`, `// ... rest of code`). Provide complete, working, syntactically accurate types, functions, and error handlers.
2. **C-Interoperability:** When bridging C libraries (`sqlite-vec`, `libgit2`), write safe Swift wrappers around unmanaged memory pointers (`UnsafeMutablePointer`, `withUnsafeBytes`, `defer { free(...) }`). Always provide the corresponding `module.modulemap`.
3. **Verification:** Every change ships with a failing-then-passing test (`swift test`). Prompt changes follow the workflow in `CLAUDE.md`.
4. **Architectural Separation:** Maintain clean boundaries between UI (`@Observable` models), Engine (`actor` isolates), and Native Bridges (`C` modules).

---

### 4. USING THE KOKORO MCP TOOLS (STANDING PRACTICE FOR CLAUDE CODE)

Registered in `.mcp.json` as `vibecockpit` (stdio shim `.build/release/kokoro-mcp` → the running app's socket). Requires the app to be running; every model query goes through `QueryGateway` (`Sources/StackCore/Inference/QueryGateway.swift`), which validates, limits and routes via `Router` and throws only `QueryError`.

* **`search_code` (RAG):** use it first for "where/how is X implemented" questions about this repo, before grep. It only works when this repo is attached as a workspace in the app (check `list_workspaces`; a different project's workspace returns "No results found", which means nothing about this repo); if absent, fall back to grep and say so. Do **not** use it for an exact symbol or string you can grep, for a file you already know the path of, or for anything you just edited (the index can lag).
* **`chat`:** for cheap local side-questions (summarise, classify). Never for work whose correctness matters more than its privacy, and never as a substitute for reading code.
* **`embed`, `list_models`:** on demand only (similarity checks; checking what is loaded).
* **`optimize_prompt`:** only when the user asks to rewrite a prompt.
* If a tool errors, report the `QueryError` message; don't retry in a loop. The local model can be unavailable under memory pressure (`list_models` shows why).
* **Which project a tool uses:** project tools (`search_code`, `read_file`, …) default to the folder the calling app is working in, taken from its MCP roots (Claude Code sends its working directory). Pass `workspace` only to override. If that folder isn't open yet, Kokoro opens it as a project automatically (persisted; never `/` or the whole home folder) and uses it. Nothing is silently redirected to another project. Clients that don't send roots keep the old rule: the only open project, else `workspace` is needed.
