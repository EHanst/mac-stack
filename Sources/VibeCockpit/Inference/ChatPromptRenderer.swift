import Foundation

/// Renders chat messages into the Qwen ChatML text the local model expects.
///
/// Every message is one self-contained segment ending in `<|im_end|>\n`, so the token count at
/// each segment boundary is a safe place to snapshot the model's cache. Assistant history is
/// rendered *exactly* as the model saw it when it generated it (generation prompt + content),
/// which keeps the previous request's prompt a strict prefix of the next one.
enum ChatPromptRenderer {

    /// Empty think block: tells the model to answer directly instead of reasoning first.
    static let emptyThink = "<think>\n\n</think>\n\n"
    static let generationPrompt = "<|im_start|>assistant\n" + emptyThink

    struct Rendered: Equatable {
        /// One entry per input message, each ending at a message boundary.
        let segments: [String]
        /// Trailing prompt that opens the assistant's reply.
        let generation: String

        var text: String { segments.joined() + generation }
    }

    static func render(_ messages: [Message]) -> Rendered {
        Rendered(segments: messages.map(segment), generation: generationPrompt)
    }

    private static func segment(_ msg: Message) -> String {
        switch msg.role {
        case .system:    "<|im_start|>system\n\(msg.content)<|im_end|>\n"
        case .user:      "<|im_start|>user\n\(msg.content)<|im_end|>\n"
        case .assistant: "<|im_start|>assistant\n\(emptyThink)\(msg.content)<|im_end|>\n"
        case .tool:      "<|im_start|>tool\n\(msg.content)<|im_end|>\n"
        }
    }
}
