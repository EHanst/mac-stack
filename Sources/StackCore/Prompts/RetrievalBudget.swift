import Foundation

/// Fits retrieved workspace code into the room a turn actually has, and recognizes that block later
/// so it can be cleared from old turns.
///
/// The chunker has no size limit (a declaration can be a whole type), so five hits could add
/// thousands of tokens to one turn, and every later request re-reads them. Retrieval is capped by
/// the space left under the local ceiling; once a turn is old, the block is replaced by a stub
/// (see `CompactionPlanner`).
public enum RetrievalBudget {

    public static let header = "Relevant code from the workspace:"
    /// What `PromptEngineer.augmentUserTurn` puts between the retrieved block and the request.
    public static let requestMarker = "\n\nUser request: "
    public static let stub = "[retrieved code cleared to save context]"

    public struct Chunk: Sendable, Equatable {
        public var fileName: String
        public var kind: String
        public var content: String
        public init(fileName: String, kind: String, content: String) {
            self.fileName = fileName; self.kind = kind; self.content = content
        }
    }

    /// At most this share of the ceiling goes to retrieval in one turn.
    public static let ceilingShare = 0.25
    /// Truncating a chunk below this many tokens isn't worth including.
    public static let minUsefulTokens = 150
    /// With no local ceiling (cloud-only) retrieval is still bounded.
    public static let cloudMaxTokens = 8_000

    /// Tokens retrieval may use now. `ceiling` is the local prompt limit (nil when there is none),
    /// `currentPromptTokens` what the conversation already holds.
    public static func maxTokens(ceiling: Int?, currentPromptTokens: Int) -> Int {
        guard let ceiling else { return cloudMaxTokens }
        let room = Int(Double(ceiling) * CompactionPlanner().triggerFraction) - currentPromptTokens
        return max(0, min(Int(Double(ceiling) * ceilingShare), room))
    }

    /// The retrieved block, best hit first, cut to `maxTokens`; nil if nothing useful fits.
    public static func render(_ chunks: [Chunk], maxTokens: Int, calibration: TokenCalibration = TokenCalibration()) -> String? {
        var lines = [header]
        var used = calibration.tokens(chars: header.count)
        var included = 0
        for chunk in chunks {
            let head = "// \(chunk.fileName) — \(chunk.kind)"
            let cost = calibration.tokens(chars: head.count + chunk.content.count + 2)
            if used + cost <= maxTokens {
                lines += [head, chunk.content, ""]
                used += cost
                included += 1
                continue
            }
            let room = maxTokens - used - calibration.tokens(chars: head.count + 40)
            if room >= minUsefulTokens {
                let chars = Int(Double(room) * calibration.charsPerToken)
                var cut = String(chunk.content.prefix(chars))
                if let newline = cut.lastIndex(of: "\n") { cut = String(cut[..<newline]) }   // whole lines only
                lines += [head, cut, "// … (cut to fit)", ""]
                included += 1
            }
            break
        }
        return included == 0 ? nil : lines.joined(separator: "\n")
    }

    /// The retrieved block inside a stored user turn, if it has one.
    public static func span(in content: String) -> Range<String.Index>? {
        guard let start = content.range(of: header),
              let end = content.range(of: requestMarker, range: start.upperBound..<content.endIndex)
        else { return nil }
        return start.lowerBound..<end.lowerBound
    }
}
