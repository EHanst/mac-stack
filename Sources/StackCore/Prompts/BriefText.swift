import Foundation

/// Cleans text that a model or a paste left with the optimizer's reply markers still in it.
public enum BriefText {
    private static let tagNames = ["improved", "changes", "questions", "draft"]

    /// Removes whole `<changes>…</changes>` / `<questions>…</questions>` blocks, then any lone
    /// reply-marker tag, then a half-arrived tag at the very end (while a reply is streaming).
    public static func stripStrayTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out = text
        for name in ["changes", "questions"] {
            out = out.replacingOccurrences(of: "<\(name)>[\\s\\S]*?</\(name)>", with: "",
                                           options: [.regularExpression, .caseInsensitive])
        }
        out = out.replacingOccurrences(of: "</?(\(tagNames.joined(separator: "|")))>", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        if let lt = out.lastIndex(of: "<"), !out[lt...].contains(">"), out.distance(from: lt, to: out.endIndex) <= 12 {
            let tail = out[lt...].lowercased()
            if tagNames.contains(where: { "<\($0)>".hasPrefix(tail) || "</\($0)>".hasPrefix(tail) }) {
                out.removeSubrange(lt...)
            }
        }
        return out == text ? text : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
