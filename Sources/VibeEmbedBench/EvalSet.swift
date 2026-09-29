/// Hand-written code-search questions over this repository. A result counts as relevant when its
/// file path ends with `file` and its chunk contains `marker` (the declaration header). Queries
/// deliberately avoid the exact identifier names, the way a user who doesn't know the code would ask.
struct EvalQuery {
    let text: String
    let file: String
    let marker: String
}

let evalSet: [EvalQuery] = [
    EvalQuery(text: "cut prefill into pieces that end exactly at message boundaries", file: "PromptSnapshotStore.swift", marker: "enum PrefillPlan"),
    EvalQuery(text: "pick the longest cached prompt prefix that matches a new prompt", file: "PromptSnapshotStore.swift", marker: "func bestMatch"),
    EvalQuery(text: "drop stale cache snapshots when memory is over the cap", file: "PromptSnapshotStore.swift", marker: "mutating func prune"),
    EvalQuery(text: "serialise GPU work with priorities and free the slot when the caller cancels", file: "InferenceScheduler.swift", marker: "actor InferenceScheduler"),
    EvalQuery(text: "choose between local and cloud model providers based on privacy policy", file: "Router.swift", marker: "enum Router"),
    EvalQuery(text: "user-facing switch for keeping data on this Mac", file: "Router.swift", marker: "enum RoutingPolicy"),
    EvalQuery(text: "try the next provider when one fails before producing any output", file: "InferenceService.swift", marker: "actor InferenceService"),
    EvalQuery(text: "estimate peak GPU memory from prompt length and decide the maximum prompt size", file: "ContextBudget.swift", marker: "struct ContextBudget"),
    EvalQuery(text: "how much memory can the system still hand out to a new allocation", file: "SystemMemory.swift", marker: "enum SystemMemory"),
    EvalQuery(text: "convert a natural language question into a full text search expression", file: "FTSQuery.swift", marker: "enum FTSQuery"),
    EvalQuery(text: "merge dense vector results with keyword results using rank fusion", file: "VectorStore.swift", marker: "func reciprocalRankFusion"),
    EvalQuery(text: "search that combines semantic similarity and keyword matching", file: "VectorStore.swift", marker: "func hybridSearch"),
    EvalQuery(text: "split source files into chunks along declaration boundaries", file: "ASTChunker.swift", marker: "actor ASTChunker"),
    EvalQuery(text: "wait for file change events to settle before reindexing", file: "FSEventDebouncer.swift", marker: "actor FSEventDebouncer"),
    EvalQuery(text: "make sure file writes stay inside the workspace and reject symlink escapes", file: "WorkspaceBoundary.swift", marker: "struct WorkspaceBoundary"),
    EvalQuery(text: "stop the retry loop after repeated identical build failures", file: "CorrectionLoop.swift", marker: "struct CorrectionLoopState"),
    EvalQuery(text: "limit how many files and how large a diff an agent run may touch", file: "ExecutionBudget.swift", marker: "struct ExecutionBudget"),
    EvalQuery(text: "unload the model after it has been idle for a while", file: "ModelRuntime.swift", marker: "actor ModelRuntime"),
    EvalQuery(text: "download model weights and verify the checksum before installing", file: "ModelDownloadManager.swift", marker: "actor ModelDownloadManager"),
    EvalQuery(text: "key value cache that grows in blocks for attention layers", file: "Qwen35Cache.swift", marker: "class Qwen35LayerCache"),
    EvalQuery(text: "run the build in a sandboxed helper process with a timeout", file: "XPCBuildRunner.swift", marker: "actor XPCBuildRunner"),
    EvalQuery(text: "store API keys securely in the macOS keychain", file: "CredentialStore.swift", marker: "actor CredentialStore"),
    EvalQuery(text: "unix domain socket transport for the model context protocol server", file: "UnixSocketTransport.swift", marker: "actor UnixSocketTransport"),
    EvalQuery(text: "expose code search and build tools to external MCP clients", file: "MCPService.swift", marker: "actor MCPService"),
    EvalQuery(text: "guess whether the user wants to debug, refactor or write tests from their prompt", file: "PromptEngineer.swift", marker: "struct PromptEngineer"),
    EvalQuery(text: "keep the exact messages sent to the model so earlier turns never change", file: "PromptLedger.swift", marker: "struct PromptLedger"),
    EvalQuery(text: "turn chat messages into the ChatML text the model expects", file: "ChatPromptRenderer.swift", marker: "enum ChatPromptRenderer"),
    EvalQuery(text: "stream tokens without emitting half of a multi byte character", file: "GenerationSupport.swift", marker: "struct StreamingDetokenizer"),
    EvalQuery(text: "hold back text that might be the start of a stop sequence", file: "GenerationSupport.swift", marker: "struct StopSequenceFilter"),
    EvalQuery(text: "fast Walsh Hadamard transform used to unrotate quantized weights", file: "PrismHadamard.swift", marker: "func prismFWHT"),
    EvalQuery(text: "web search tool that calls the Brave search API", file: "WebResearchTool.swift", marker: "struct WebSearchTool"),
    EvalQuery(text: "fetch a web page and strip the html tags for the agent", file: "WebResearchTool.swift", marker: "struct WebFetchTool"),
    EvalQuery(text: "create and restore snapshots of the working tree with libgit2", file: "GitSnapshotManager.swift", marker: "actor GitSnapshotManager"),
    EvalQuery(text: "send code chunks to the embedding model in batches", file: "EmbeddingScheduler.swift", marker: "actor EmbeddingScheduler"),
    EvalQuery(text: "pure reducer that applies commands to the app state", file: "AppCoordinator.swift", marker: "class AppCoordinator"),
]
