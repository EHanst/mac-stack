import Foundation

/// Where the finished prompt is going to be pasted. The surface decides whether files are worth
/// inlining: some tools read the repo themselves.
public enum ContextMode: String, Codable, Sendable { case inline, reference }

public enum Surface: String, Codable, Sendable, CaseIterable {
    case claudeCode, cursor, chatGPTWeb, claudeDesktop, other

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .chatGPTWeb: "ChatGPT (web)"
        case .claudeDesktop: "Claude Desktop"
        case .other: "Other"
        }
    }

    public var defaultContextMode: ContextMode {
        switch self {
        case .claudeCode, .cursor: .reference
        case .chatGPTWeb, .claudeDesktop, .other: .inline
        }
    }
}

/// A target model family on a target surface, with the token budget the compiler must respect.
public struct TargetProfile: Codable, Sendable, Equatable {
    public var modelFamily: String
    public var surface: Surface
    public var tokenBudget: Int

    public init(modelFamily: String, surface: Surface, tokenBudget: Int) {
        self.modelFamily = modelFamily
        self.surface = surface
        self.tokenBudget = tokenBudget
    }

    public static func make(modelFamily: String, surface: Surface) -> TargetProfile {
        let model = profile(forFamily: modelFamily)
        return TargetProfile(modelFamily: modelFamily, surface: surface, tokenBudget: model.maxUsefulTokens)
    }

    public var model: ModelPromptProfile { Self.profile(forFamily: modelFamily) }
    public var structure: ModelPromptProfile.Structure { model.structure }

    private static func profile(forFamily family: String) -> ModelPromptProfile {
        switch family {
        case "claude": .claude
        case "gpt": .gpt
        case "local": .localSmall
        default: .generic
        }
    }
}
