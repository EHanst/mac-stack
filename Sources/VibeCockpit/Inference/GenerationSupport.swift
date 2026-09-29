import Foundation

// Pure helpers for the local generation loop. They deliberately have no MLX dependency so the
// decode-loop bookkeeping can be unit-tested without a GPU or model weights.

/// Length of the shared leading run of `a` and `b`.
func commonPrefixLength<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    let n = min(a.count, b.count)
    var i = 0
    while i < n && a[i] == b[i] { i += 1 }
    return i
}

/// Turns a token stream into text without splitting multi-byte characters.
///
/// Byte-level BPE can spread one UTF-8 character (emoji, CJK) over several tokens; decoding a
/// lone token in the middle of such a sequence yields U+FFFD. Tokens are buffered until they
/// decode cleanly, then flushed as one chunk.
struct StreamingDetokenizer {
    private let decode: ([Int]) -> String
    private var pending: [Int] = []
    /// Give up waiting for a clean decode after this many tokens (a genuine U+FFFD).
    private let maxPending = 8

    init(decode: @escaping ([Int]) -> String) {
        self.decode = decode
    }

    /// Add a token; returns newly completed text (possibly empty while a character is split).
    mutating func append(_ token: Int) -> String {
        pending.append(token)
        let text = decode(pending)
        if text.hasSuffix("\u{FFFD}") && pending.count < maxPending { return "" }
        pending.removeAll(keepingCapacity: true)
        return text
    }

    /// Emit whatever is still buffered (end of generation).
    mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        let text = decode(pending)
        pending.removeAll(keepingCapacity: true)
        return text
    }
}

/// Detects stop sequences that may straddle chunk boundaries.
///
/// The last `longestStop - 1` characters are held back until it is clear they can't be the
/// start of a stop sequence, so stop text is never emitted. With no stop sequences it is a
/// zero-latency pass-through.
struct StopSequenceFilter {
    private let stops: [String]
    private let holdBack: Int
    private var buffer = ""

    init(stops: [String]) {
        let usable = stops.filter { !$0.isEmpty }
        self.stops = usable
        self.holdBack = max(0, (usable.map(\.count).max() ?? 0) - 1)
    }

    /// Feed a chunk. Returns text that is safe to emit and whether a stop sequence was hit
    /// (in which case nothing after it is returned and the stream should end).
    mutating func push(_ chunk: String) -> (emit: String, stopped: Bool) {
        guard !stops.isEmpty else { return (chunk, false) }
        buffer += chunk

        let hit = stops
            .compactMap { buffer.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        if let hit {
            let out = String(buffer[..<hit.lowerBound])
            buffer = ""
            return (out, true)
        }

        let keep = min(holdBack, buffer.count)
        let split = buffer.index(buffer.endIndex, offsetBy: -keep)
        let out = String(buffer[..<split])
        buffer = String(buffer[split...])
        return (out, false)
    }

    /// Release held-back text once generation ends without a stop hit.
    mutating func flush() -> String {
        defer { buffer = "" }
        return buffer
    }
}
