/// Prompt-lookup drafting for speculative decoding: a rewrite copies literals, paths and quoted text
/// from its request, so after the last few generated tokens the next ones are often the tokens that
/// followed the same run earlier in the context. Those are proposed as a free draft and checked by the
/// model in one multi-token pass; only tokens matching the model's own greedy picks are kept.
enum PromptLookup {

    /// The tokens (at most `maxDraft`) that followed the most recent earlier occurrence of the
    /// context's trailing n-gram, trying the longest n first; empty when nothing matches.
    static func draft(_ context: [Int32], maxDraft: Int, ngram: ClosedRange<Int> = 2...3) -> [Int32] {
        guard maxDraft > 0, ngram.lowerBound > 0 else { return [] }
        let count = context.count
        return context.withUnsafeBufferPointer { c -> [Int32] in
            for n in ngram.reversed() where count > n {
                let suffix = count - n
                // Latest start first; `start < suffix` keeps the trailing n-gram from matching itself.
                var start = suffix - 1
                while start >= 0 {
                    var match = true
                    for j in 0..<n where c[start + j] != c[suffix + j] { match = false; break }
                    if match {
                        let from = start + n
                        return Array(c[from ..< min(from + maxDraft, count)])
                    }
                    start -= 1
                }
            }
            return []
        }
    }

    /// How many leading drafts equal the model's picks (`picks[i]` is its choice at draft `i`'s position).
    static func acceptedCount(drafts: [Int32], picks: [Int32]) -> Int {
        var a = 0
        while a < drafts.count, a < picks.count, drafts[a] == picks[a] { a += 1 }
        return a
    }
}
