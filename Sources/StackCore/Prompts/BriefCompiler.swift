import Foundation

public struct BriefWarning: Sendable, Equatable {
    public enum Code: String, Sendable {
        case emptyGoal, overBudget, itemDowngraded, itemDropped, referenceWithoutPath, sectionsOverBudget
    }
    public var code: Code
    public var message: String
    public var itemID: String?
}

public struct CompiledPrompt: Sendable, Equatable {
    public var text: String
    public var tokens: Int
    public var warnings: [BriefWarning]
    public var includedItemIDs: [String]
}

/// Turns a `Brief` into the text a frontier model receives. Pure: no model calls, no I/O, so the
/// same brief always compiles to the same text. Nothing is dropped without a warning.
public enum BriefCompiler {

    public static func compile(_ brief: Brief) -> CompiledPrompt {
        var warnings: [BriefWarning] = []
        let structure = brief.target.structure
        let budget = brief.target.tokenBudget

        if brief.sections.first(where: { $0.kind == .goal && $0.enabled })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            warnings.append(.init(code: .emptyGoal, message: "Say what you want done.", itemID: nil))
        }

        var items: [ContextItem] = []
        for item in brief.contextItems where item.included {
            if item.mode == .reference && item.ref.trimmingCharacters(in: .whitespaces).isEmpty {
                warnings.append(.init(code: .referenceWithoutPath, message: "A context item has no path, so it was left out.", itemID: item.id))
            } else {
                items.append(item)
            }
        }
        // Files before diffs: the diff is the part most likely to change between drafts.
        items.sort { ($0.kind == .gitDiff ? 1 : 0) < ($1.kind == .gitDiff ? 1 : 0) }

        func render(_ items: [ContextItem]) -> String {
            renderText(brief, items: items, structure: structure)
        }

        var text = render(items)
        var tokens = PromptTokens.estimate(text)

        // 1. Over budget: point at files instead of pasting them, least important first.
        if tokens > budget {
            for id in items.filter({ $0.mode == .inline }).sorted(by: { $0.priority < $1.priority }).map(\.id) {
                guard tokens > budget, let i = items.firstIndex(where: { $0.id == id }) else { continue }
                if items[i].ref.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                items[i].mode = .reference
                warnings.append(.init(code: .itemDowngraded, message: "\(items[i].ref) is referenced by path to fit the budget.", itemID: id))
                text = render(items); tokens = PromptTokens.estimate(text)
            }
        }
        // 2. Still over: drop the least important items.
        if tokens > budget {
            for id in items.sorted(by: { $0.priority < $1.priority }).map(\.id) {
                guard tokens > budget, let i = items.firstIndex(where: { $0.id == id }) else { continue }
                let dropped = items.remove(at: i)
                warnings.append(.init(code: .itemDropped, message: "\(dropped.ref) was left out to fit the budget.", itemID: id))
                text = render(items); tokens = PromptTokens.estimate(text)
            }
        }
        if tokens > budget {
            let sectionsOnly = renderText(brief, items: [], structure: structure)
            let code: BriefWarning.Code = items.isEmpty && PromptTokens.estimate(sectionsOnly) > budget ? .sectionsOverBudget : .overBudget
            warnings.append(.init(code: code, message: "The brief is longer than this target handles well (about \(budget) tokens).", itemID: nil))
        }
        return CompiledPrompt(text: text, tokens: tokens, warnings: warnings, includedItemIDs: items.map(\.id))
    }

    // MARK: Rendering

    private static let order: [BriefSection.Kind] = [.goal, .context, .constraints, .examples, .outputFormat]

    private static func renderText(_ brief: Brief, items: [ContextItem], structure: ModelPromptProfile.Structure) -> String {
        var blocks: [String] = []
        for kind in order {
            var body = brief.sections.first { $0.kind == kind && $0.enabled }?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if kind == .context, !items.isEmpty {
                let rendered = items.map { renderItem($0, structure: structure) }.joined(separator: "\n")
                body = body.isEmpty ? rendered : body + "\n" + rendered
            }
            guard !body.isEmpty else { continue }
            if kind == .constraints, structure == .plainNumbered {
                body = body.split(separator: "\n", omittingEmptySubsequences: true).enumerated()
                    .map { "\($0.offset + 1). \($0.element.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
            }
            blocks.append(wrap(body, kind: kind, structure: structure))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func wrap(_ body: String, kind: BriefSection.Kind, structure: ModelPromptProfile.Structure) -> String {
        switch structure {
        case .xmlTags:
            let tag = kind.rawValue.lowercased()
            return "<\(tag)>\n\(neutralize(body, keepingKnownTags: true))\n</\(tag)>"
        case .markdown, .plainNumbered:
            return "## \(title(kind))\n\(body)"
        }
    }

    private static func title(_ kind: BriefSection.Kind) -> String {
        switch kind {
        case .goal: "Goal"
        case .context: "Context"
        case .constraints: "Constraints"
        case .examples: "Examples"
        case .outputFormat: "Output format"
        }
    }

    private static func renderItem(_ item: ContextItem, structure: ModelPromptProfile.Structure) -> String {
        if item.mode == .reference { return "See \(item.ref)" }
        switch structure {
        case .xmlTags:
            return "<file path=\"\(item.ref.replacingOccurrences(of: "\"", with: "&quot;"))\">\n\(neutralize(item.text, keepingKnownTags: false))\n</file>"
        case .markdown, .plainNumbered:
            var fence = "```"
            while item.text.contains(fence) { fence += "`" }
            return "\(item.ref):\n\(fence)\n\(item.text)\n\(fence)"
        }
    }

    /// Stops pasted text from closing the tag it sits in. Section text written by the user keeps its
    /// own tags (`keepingKnownTags`); pasted file text keeps none.
    private static func neutralize(_ text: String, keepingKnownTags: Bool) -> String {
        if keepingKnownTags {
            // Only the file wrapper is ours inside a section, so protect closing tags inside inlined files
            // by leaving user prose alone but escaping stray closers of the section tags themselves.
            var out = text
            for kind in BriefSection.Kind.allCases {
                out = out.replacingOccurrences(of: "</\(kind.rawValue.lowercased())>", with: "<\\/\(kind.rawValue.lowercased())>")
            }
            return out
        }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }
}
