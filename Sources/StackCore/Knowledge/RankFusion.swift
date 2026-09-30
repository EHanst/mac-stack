import Foundation

/// Reciprocal rank fusion over ranked id lists. Same formula as `VectorStore`'s, but over plain ids.
enum RankFusion {
    static func fuse(_ lists: [[String]], k: Int = 60) -> [(id: String, score: Double)] {
        var scores: [String: Double] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() { scores[id, default: 0] += 1.0 / Double(k + rank + 1) }
        }
        return scores.map { (id: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }
}
