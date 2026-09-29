/// Groups texts into batches of similar length so padding is minimal, remembering where each
/// text came from so results can be returned in the caller's order.
enum EmbeddingBatching {
    /// Index groups (into the original array), each at most `batchSize`, shortest texts first.
    static func plan(lengths: [Int], batchSize: Int) -> [[Int]] {
        guard batchSize > 0 else { return [] }
        let order = lengths.indices.sorted { lengths[$0] < lengths[$1] }
        return stride(from: 0, to: order.count, by: batchSize).map {
            Array(order[$0..<min($0 + batchSize, order.count)])
        }
    }
}
