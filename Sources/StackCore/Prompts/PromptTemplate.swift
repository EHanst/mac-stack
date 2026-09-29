import Foundation

/// `{{variable}}` substitution for saved prompts.
///
/// Rendering is a single pass: a value that itself contains `{{x}}` is inserted as plain text and
/// never expanded again, so text pulled in from a file, the clipboard or a repository prompt can't
/// smuggle in another variable.
public enum PromptTemplate {

    /// Variables the app can fill in by itself; everything else is asked for in a form.
    public static let builtIns: [String] = ["selection", "file", "workspace", "date", "clipboard", "git_diff"]

    /// Variable names in order of first appearance, without duplicates.
    public static func variables(in body: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        scan(body) { token in
            if case .variable(let name) = token, seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// Variables the user must type (not built in).
    public static func askedVariables(in body: String) -> [String] {
        variables(in: body).filter { !builtIns.contains($0) }
    }

    /// Fills in `values`. A variable with no value is left as written (`{{name}}`) so a missing one
    /// is visible instead of silently becoming an empty string.
    public static func render(_ body: String, values: [String: String]) -> String {
        var out = ""
        scan(body) { token in
            switch token {
            case .text(let t): out += t
            case .variable(let name): out += values[name] ?? "{{\(name)}}"
            }
        }
        return out
    }

    // MARK: Scanner

    private enum Token { case text(String), variable(String) }

    private static func isNameStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
    private static func isNameChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private static func scan(_ body: String, _ emit: (Token) -> Void) {
        let chars = Array(body)
        var text = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] == "{" {
                var j = i + 2
                while j < chars.count, chars[j] == " " { j += 1 }
                let start = j
                if j < chars.count, isNameStart(chars[j]) {
                    while j < chars.count, isNameChar(chars[j]) { j += 1 }
                    let name = String(chars[start..<j])
                    while j < chars.count, chars[j] == " " { j += 1 }
                    if j + 1 < chars.count, chars[j] == "}", chars[j + 1] == "}" {
                        if !text.isEmpty { emit(.text(text)); text = "" }
                        emit(.variable(name))
                        i = j + 2
                        continue
                    }
                }
            }
            text.append(chars[i])
            i += 1
        }
        if !text.isEmpty { emit(.text(text)) }
    }
}
