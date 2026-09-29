import Foundation

// Prefix-cache bookkeeping for the local generation loop. Generic over the payload and free of
// MLX so the policy (which snapshot to restore, what to evict) can be unit-tested without a GPU.

/// A set of cache snapshots taken at different points of previously-seen prompts.
///
/// Recurrent (linear-attention) state can't be rewound, so a snapshot is only usable when the
/// new prompt begins with *exactly* its tokens. Keeping several — end of the system prompt and
/// each message boundary — means a partial match still restores the longest common prefix
/// instead of falling back to prefilling everything.
struct PromptSnapshotStore<Payload> {

    enum Kind: Equatable {
        /// End of the system message. Shared by every session, so it survives pruning — but only
        /// one is kept: a new system prompt supersedes the old one.
        case system
        /// End of a message; safe cut point between turns.
        case boundary
        /// End of the whole prompt; only one is kept.
        case tail
    }

    struct Entry {
        let tokens: [Int32]
        let payload: Payload
        let bytes: Int
        let kind: Kind
    }

    private(set) var entries: [Entry] = []
    let maxEntries: Int
    let maxBytes: Int

    init(maxEntries: Int = 6, maxBytes: Int = 2 << 30) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes } }
    var count: Int { entries.count }

    mutating func removeAll() { entries.removeAll() }

    /// Longest stored prefix of `prompt` that is at most `maxLength` tokens.
    func bestMatch(for prompt: [Int32], maxLength: Int) -> Entry? {
        entries
            .filter { !$0.tokens.isEmpty && $0.tokens.count <= maxLength
                && commonPrefixLength($0.tokens, prompt) == $0.tokens.count }
            .max { $0.tokens.count < $1.tokens.count }
    }

    /// Store a snapshot, replacing any entry for the same token sequence; a new `.tail` or
    /// `.system` replaces the previous one of that kind.
    mutating func insert(tokens: [Int32], payload: Payload, bytes: Int, kind: Kind) {
        entries.removeAll {
            $0.tokens == tokens || (kind != .boundary && $0.kind == kind)
        }
        entries.append(Entry(tokens: tokens, payload: payload, bytes: bytes, kind: kind))
    }

    /// Keep the longest prefixes that fit in `limit` bytes (the `.system` entry is tiny and always
    /// kept); drop the rest. Used when the model's weights are unloaded after sitting idle: a small
    /// cache is worth keeping so coming back doesn't mean re-reading the whole conversation.
    mutating func retain(upToBytes limit: Int) {
        var used = 0
        var keep: [Entry] = []
        for entry in entries.sorted(by: { $0.tokens.count > $1.tokens.count }) {
            if entry.kind == .system || used + entry.bytes <= limit {
                keep.append(entry)
                used += entry.bytes
            }
        }
        entries = entries.filter { e in keep.contains { $0.tokens == e.tokens } }
    }

    /// Drop stale entries, then enforce the count and byte caps.
    ///
    /// Conversations only grow, so an entry that is not a prefix of the prompt just served
    /// belongs to a dead branch (cleared or trimmed session) — except `.system`, which the next
    /// session will match again. Over the caps, the shortest prefix goes first: it saves the
    /// least, and the longest is what the next turn will hit.
    mutating func prune(keepingPrefixesOf prompt: [Int32]) {
        entries.removeAll {
            $0.kind != .system && commonPrefixLength($0.tokens, prompt) != $0.tokens.count
        }
        while entries.count > maxEntries || totalBytes > maxBytes {
            let longest = entries.map { $0.tokens.count }.max() ?? 0
            let victim = entries.indices
                .filter { entries[$0].kind != .system && entries[$0].tokens.count != longest }
                .min { entries[$0].tokens.count < entries[$1].tokens.count }
            guard let v = victim else { break }
            entries.remove(at: v)
        }
    }
}

/// Where to cut a prefill into chunks so a snapshot can be taken exactly at each stop.
enum PrefillPlan {

    /// Ranges covering `start..<end`, at most `chunk` long, each ending on a stop (or `end`).
    static func chunks(from start: Int, to end: Int, chunk: Int, stops: [Int]) -> [Range<Int>] {
        guard end > start, chunk > 0 else { return [] }
        let cuts = Set(stops.filter { $0 > start && $0 < end })
        var ranges: [Range<Int>] = []
        var i = start
        while i < end {
            var j = min(i + chunk, end)
            if let stop = cuts.filter({ $0 > i && $0 < j }).min() { j = stop }
            ranges.append(i..<j)
            i = j
        }
        return ranges
    }

    /// Message-boundary token offsets worth snapshotting for this request (beyond what was
    /// already restored, and within the prefilled region).
    static func snapshotStops(boundaries: [Int], restoredUpTo consumed: Int, prefillEnd: Int) -> [Int] {
        Array(Set(boundaries.filter { $0 > consumed && $0 <= prefillEnd })).sorted()
    }
}
