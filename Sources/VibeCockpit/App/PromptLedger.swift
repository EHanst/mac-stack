import Foundation
#if SWIFT_PACKAGE
import StackCore
#endif

/// `MCP` also defines `Message`; AppServices imports both, so it uses this unambiguous name.
typealias ChatMessage = Message

/// The exact messages sent to the model, kept append-only.
///
/// Local inference reuses the KV/recurrent cache only for an exact token prefix, so anything
/// that rewrites earlier text (re-running prompt engineering, re-injecting RAG, re-deriving the
/// system prompt) throws away the whole cache. The ledger builds each message once, stores it
/// verbatim, and only ever appends — except `trim`, which drops whole old turns permanently so
/// the prompt is stable again immediately afterwards.
public struct PromptLedger: Sendable {

    public private(set) var messages: [Message] = []
    /// Number of user turns appended (used to detect a cleared or out-of-sync session).
    public private(set) var userTurns = 0

    public init() {}

    public var isEmpty: Bool { messages.isEmpty }

    public mutating func reset() {
        messages = []
        userTurns = 0
    }

    /// Start a session: the system message is built once, and `prior` (already-final history,
    /// e.g. rebuilt after a restart) follows it verbatim.
    public mutating func begin(system: String, prior: [Message] = []) {
        messages = [Message(role: .system, content: system)] + prior
        userTurns = prior.filter { $0.role == .user }.count
    }

    /// Append a fully-augmented user message exactly as it will be sent.
    public mutating func appendUserTurn(_ content: String) {
        messages.append(Message(role: .user, content: content))
        userTurns += 1
    }

    /// Append what the model actually produced. Empty output is ignored.
    public mutating func appendAssistant(_ text: String) {
        guard !text.isEmpty else { return }
        messages.append(Message(role: .assistant, content: text))
    }

    public mutating func appendToolResult(id: String, content: String) {
        messages.append(Message(role: .tool, content: content, toolCallID: id))
    }

    /// Drop the oldest whole turns until the conversation fits `maxCharacters`. The system
    /// message and the most recent turn are always kept. Returns true if anything was dropped.
    @discardableResult
    public mutating func trim(toCharacterBudget maxCharacters: Int) -> Bool {
        var trimmed = false
        while messages.reduce(0, { $0 + $1.content.count }) > maxCharacters {
            let userIndices = messages.indices.filter { messages[$0].role == .user }
            guard userIndices.count >= 2 else { break }
            messages.removeSubrange(1..<userIndices[1])   // oldest turn: up to the next user message
            trimmed = true
        }
        return trimmed
    }

    // MARK: Compaction

    /// The ledger as the compaction planner sees it. Tool output is always untrusted (web pages,
    /// MCP results, file reads), so a stub or summary of it stays untrusted too.
    public func compactionItems() -> [CompactionPlanner.Item] {
        messages.map {
            CompactionPlanner.Item(role: $0.role, tokens: InferenceService.estimateTokens([$0]),
                                   isUntrusted: $0.role == .tool)
        }
    }

    /// Replace the tool messages at `indices` with short stubs, once. Returns the tokens freed.
    /// This is a deliberate one-time rewrite of earlier text: the cached prefix is lost from the
    /// first stub onward, so callers batch it (see `CompactionPlanner`) instead of doing it per turn.
    @discardableResult
    public mutating func elide(_ indices: [Int]) -> Int {
        var freed = 0
        for i in indices where messages.indices.contains(i) && messages[i].role == .tool {
            let old = messages[i]
            let stub = Message(role: .tool,
                               content: "[tool output cleared to save context: about \(InferenceService.estimateTokens([old])) tokens]",
                               toolCallID: old.toolCallID)
            freed += InferenceService.estimateTokens([old]) - InferenceService.estimateTokens([stub])
            messages[i] = stub
        }
        return freed
    }
}
