import Foundation

public struct BriefWarning: Sendable, Equatable {
    public enum Code: String, Sendable {
        case emptyInput, overBudget, itemDowngraded, itemDropped, referenceWithoutPath, bodyOverBudget, secretRedacted, lintFinding
    }
    public var code: Code
    public var message: String
    public var itemID: String?

    public init(code: Code, message: String, itemID: String? = nil) {
        self.code = code
        self.message = message
        self.itemID = itemID
    }
}

public struct CompiledPrompt: Sendable, Equatable {
    public var text: String
    public var tokens: Int
    public var warnings: [BriefWarning]
    public var includedItemIDs: [String]
    public var redactedCount: Int = 0
}

/// Turns a `Brief` into the text a frontier model receives. Pure: no model calls, no I/O, so the
/// same brief always compiles to the same text. Nothing is dropped without a warning.
public enum BriefCompiler {

    /// `compact` renders the machine form (see `renderCompact`): same content and the same budget
    /// handling, fewer tokens. The default is the readable form.
    public static func compile(_ original: Brief) -> CompiledPrompt { compile(original, compact: false) }

    public static func compile(_ original: Brief, compact: Bool) -> CompiledPrompt {
        var warnings: [BriefWarning] = []
        var totalRedactions = 0
        var brief = original

        // Nothing leaves the app with a credential in it, whether from the text or an attached item.
        // Only what will actually be emitted is counted, so a hidden secret does not raise a warning.
        let body = ContextRedactor.redact(original.effectiveBody)
        if body.count > 0 {
            totalRedactions += body.count
            warnings.append(.init(code: .secretRedacted,
                                  message: "\(body.count) secret\(body.count == 1 ? " was" : "s were") removed from your text.",
                                  itemID: nil))
        }

        for i in brief.contextItems.indices {
            let redactedText = ContextRedactor.redact(brief.contextItems[i].text)
            let redactedRef = ContextRedactor.redact(brief.contextItems[i].ref)
            brief.contextItems[i].text = redactedText.text
            brief.contextItems[i].ref = redactedRef.text
            if brief.contextItems[i].included, redactedText.count + redactedRef.count > 0 {
                let n = redactedText.count + redactedRef.count
                totalRedactions += n
                warnings.append(.init(code: .secretRedacted,
                                      message: "\(n) secret\(n == 1 ? " was" : "s were") removed from \(brief.contextItems[i].ref).",
                                      itemID: brief.contextItems[i].id))
            }
        }

        let structure = brief.target.structure
        let budget = brief.target.tokenBudget

        if body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append(.init(code: .emptyInput, message: "Say what you want done.", itemID: nil))
        }

        var items: [ContextItem] = []
        for item in brief.contextItems where item.included {
            if item.mode == .reference && hasNoPath(item) {
                warnings.append(.init(code: .referenceWithoutPath, message: "A context item has no path, so it was left out.", itemID: item.id))
            } else {
                items.append(item)
            }
        }
        // Files before diffs: the diff is the part most likely to change between drafts.
        items.sort { ($0.kind == .gitDiff ? 1 : 0) < ($1.kind == .gitDiff ? 1 : 0) }

        func byImportance(_ a: ContextItem, _ b: ContextItem) -> Bool {
            a.priority != b.priority ? a.priority < b.priority : a.id < b.id
        }

        func render(_ items: [ContextItem]) -> String {
            compact ? renderCompact(body.text, items: items, structure: structure)
                    : renderText(body.text, items: items, structure: structure)
        }

        var text = render(items)
        var tokens = PromptTokens.estimate(text)

        // 1. Over budget: point at files instead of pasting them, least important first. Only for a
        // target that can read the repo itself, and only for things that have a path.
        if tokens > budget, brief.target.surface.defaultContextMode == .reference {
            for id in items.filter({ $0.mode == .inline && $0.kind != .gitDiff && $0.kind != .snippet }).sorted(by: byImportance).map(\.id) {
                guard tokens > budget, let i = items.firstIndex(where: { $0.id == id }) else { continue }
                if hasNoPath(items[i]) { continue }
                items[i].mode = .reference
                warnings.append(.init(code: .itemDowngraded, message: "\(items[i].ref) is referenced by path to fit the budget.", itemID: id))
                text = render(items); tokens = PromptTokens.estimate(text)
            }
        }
        // 2. Still over: drop the least important items.
        if tokens > budget {
            for id in items.sorted(by: byImportance).map(\.id) {
                guard tokens > budget, let i = items.firstIndex(where: { $0.id == id }) else { continue }
                let dropped = items.remove(at: i)
                warnings.append(.init(code: .itemDropped, message: "\(dropped.ref) was left out to fit the budget.", itemID: id))
                text = render(items); tokens = PromptTokens.estimate(text)
            }
        }
        if tokens > budget {
            warnings.append(.init(code: .overBudget, message: "The brief is about \(tokens) tokens, over this target's budget of about \(budget).", itemID: nil))
            if PromptTokens.estimate(render([])) > budget {
                warnings.append(.init(code: .bodyOverBudget, message: "Your text is longer than this target handles well. Shorten it.", itemID: nil))
            }
        }
        return CompiledPrompt(text: text, tokens: tokens, warnings: warnings,
                              includedItemIDs: items.map(\.id), redactedCount: totalRedactions)
    }

    private static func hasNoPath(_ item: ContextItem) -> Bool {
        item.ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A path is shown on one line: a newline in a file name must not start a new line of the prompt.
    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func attribute(_ s: String) -> String {
        oneLine(s).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Compact rendering

    /// Data-dense form for a model reader: no prose framing, no markdown decoration, no blank lines.
    /// Code, diffs and anything inside a fenced block keep their text; only trailing spaces go.
    private static func renderCompact(_ body: String, items: [ContextItem], structure: ModelPromptProfile.Structure) -> String {
        let task = compactProse(body)
        var out: [String] = []
        switch structure {
        case .xmlTags:
            if !task.isEmpty {
                // A body that already carries its own <task> block is passed through, not nested.
                if task.range(of: "<task>", options: .caseInsensitive) != nil { out.append(task) }
                else { out.append("<task>\n" + task.replacingOccurrences(of: "</task", with: "<\\/task", options: .caseInsensitive) + "\n</task>") }
            }
            for item in items {
                if item.mode == .reference { out.append("<ref p=\"\(attribute(item.ref))\"/>"); continue }
                out.append("<file p=\"\(attribute(item.ref))\">\n" + neutralize(compactItemText(item)) + "\n</file>")
            }
        case .markdown:
            if !task.isEmpty { out.append("# task\n" + task) }
            for item in items {
                if item.mode == .reference { out.append("# ref " + oneLine(item.ref)); continue }
                let text = compactItemText(item)
                var fence = "```"
                while text.contains(fence) { fence += "`" }
                out.append("# file " + oneLine(item.ref) + "\n" + fence + "\n" + text + "\n" + fence)
            }
        case .plainNumbered:
            out.append("#FMT task first. #FILE <path> = file text follows, until the next # line. #REF <path> = read it yourself.")
            if !task.isEmpty { out.append("#TASK\n" + task) }
            for item in items {
                if item.mode == .reference { out.append("#REF " + oneLine(item.ref)); continue }
                out.append("#FILE " + oneLine(item.ref) + "\n" + compactItemText(item))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func compactItemText(_ item: ContextItem) -> String {
        item.kind == .gitDiff ? item.text.trimmingCharacters(in: .newlines) : dropBlankLines(item.text)
    }

    private static func dropBlankLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = String(line)
                while l.last == " " || l.last == "\t" { l.removeLast() }
                return l
            }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Strips what a model reads no differently: heading, list, numbering and quote markers, rules,
    /// table rules, emphasis, link syntax. Nesting is kept as halved indentation and order as line
    /// order; fenced code passes through.
    private static func compactProse(_ text: String) -> String {
        var inFence = false
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { line.removeLast() }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); lines.append(line); continue }
            if inFence { lines.append(line); continue }
            if line.isEmpty || line.range(of: rulePattern, options: .regularExpression) != nil { continue }
            if let r = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) { line.removeSubrange(r) }
            let pad = line.prefix { $0 == " " }.count
            var body = String(line.dropFirst(pad))
            while let r = body.range(of: #"^>\s?"#, options: .regularExpression) { body.removeSubrange(r) }
            if let r = body.range(of: #"^([-*+•]|\d{1,4}[.)])\s+"#, options: .regularExpression) { body.removeSubrange(r) }
            if body.hasPrefix("|"), body.hasSuffix("|"), body.count > 1 {
                body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            body = body.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            body = body.replacingOccurrences(of: #"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, with: "$1", options: .regularExpression)
            body = body.replacingOccurrences(of: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
            if body.isEmpty { continue }
            lines.append(String(repeating: " ", count: pad > 1 ? pad / 2 : pad) + body)
        }
        return lines.joined(separator: "\n")
    }

    /// A horizontal rule (`---`, `* * *`) or a table's header rule (`|---|:--:|`).
    private static let rulePattern = #"^\s*(([-*_])(\s*\2){2,}|\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?)\s*$"#

    // MARK: Rendering

    private static func renderText(_ body: String, items: [ContextItem], structure: ModelPromptProfile.Structure) -> String {
        var blocks: [String] = []
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(trimmed)
        }
        if !items.isEmpty {
            blocks.append(items.map { renderItem($0, structure: structure) }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func renderItem(_ item: ContextItem, structure: ModelPromptProfile.Structure) -> String {
        if item.mode == .reference { return "See \(oneLine(item.ref))" }
        switch structure {
        case .xmlTags:
            return "<file path=\"\(attribute(item.ref))\">\n\(neutralize(item.text))\n</file>"
        case .markdown, .plainNumbered:
            var fence = "```"
            while item.text.contains(fence) { fence += "`" }
            return "\(oneLine(item.ref)):\n\(fence)\n\(item.text)\n\(fence)"
        }
    }

    /// Stops pasted file text from closing the `<file>` tag it sits in. Only `</file` is escaped,
    /// so code such as `</div>` reaches the model unchanged.
    private static func neutralize(_ text: String) -> String {
        text.replacingOccurrences(of: "</file", with: "<\\/file", options: .caseInsensitive)
    }
}
