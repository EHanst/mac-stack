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
    public func compactionItems(calibration: TokenCalibration = TokenCalibration()) -> [CompactionPlanner.Item] {
        messages.map { m in
            var bulk: Int?
            if m.role == .user, let span = RetrievalBudget.span(in: m.content) {
                bulk = calibration.tokens(chars: m.content[span].count)   // retrieved code inside a user turn
            }
            return CompactionPlanner.Item(role: m.role, tokens: calibration.tokens(of: [m]),
                                          isUntrusted: m.role == .tool, bulkTokens: bulk)
        }
    }

    /// Replace the bulky part of the messages at `indices` with short stubs, once: a tool result, or the
    /// retrieved code inside a user turn. Returns the tokens freed.
    /// This is a deliberate one-time rewrite of earlier text: the cached prefix is lost from the
    /// first stub onward, so callers batch it (see `CompactionPlanner`) instead of doing it per turn.
    @discardableResult
    public mutating func elide(_ indices: [Int], calibration: TokenCalibration = TokenCalibration()) -> Int {
        var freed = 0
        for i in indices where messages.indices.contains(i) {
            let old = messages[i]
            let replacement: Message
            switch old.role {
            case .tool:
                replacement = Message(role: .tool,
                                      content: "[tool output cleared to save context: about \(calibration.tokens(of: [old])) tokens]",
                                      toolCallID: old.toolCallID)
            case .user:
                // Retrieved code that was useful for one answer; the request and any guidance stay.
                guard let span = RetrievalBudget.span(in: old.content) else { continue }
                var text = old.content
                text.replaceSubrange(span, with: RetrievalBudget.stub)
                replacement = Message(role: .user, content: text, toolCallID: old.toolCallID)
            default:
                continue
            }
            freed += calibration.tokens(of: [old]) - calibration.tokens(of: [replacement])
            messages[i] = replacement
        }
        return freed
    }

    /// Replace `range` with one summary message, only if it still holds exactly `expected` (the
    /// ledger may have grown or been trimmed while the summary was written). The summary is an
    /// assistant message so the system message stays first and `userTurns` stays in step with the
    /// visible chat. Returns the tokens freed, or nil if the ledger changed.
    @discardableResult
    public mutating func summarize(_ range: Range<Int>, expecting expected: [Message], text: String,
                                   calibration: TokenCalibration = TokenCalibration()) -> Int? {
        guard range.lowerBound >= 1, range.upperBound <= messages.count, range.count == expected.count,
              zip(messages[range], expected).allSatisfy({ $0.role == $1.role && $0.content == $1.content && $0.toolCallID == $1.toolCallID })
        else { return nil }
        let summary = Message(role: .assistant, content: text)
        let freed = calibration.tokens(of: Array(messages[range])) - calibration.tokens(of: [summary])
        messages.replaceSubrange(range, with: [summary])
        return freed
    }
}
