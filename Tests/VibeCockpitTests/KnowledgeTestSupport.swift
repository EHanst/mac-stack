import Foundation
@testable import StackCore

enum KnowledgeStub {
    static let dim = 32

    /// Deterministic bag-of-words embedding: texts sharing words are close. No model needed.
    static func vector(_ text: String, dim: Int = KnowledgeStub.dim) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var h: UInt64 = 1469598103934665603
            for b in w.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(dim))] += 1
        }
        let norm = max(v.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-6)
        return v.map { $0 / norm }
    }

    static func embedder(dim: Int = KnowledgeStub.dim) -> KnowledgeEmbedder {
        KnowledgeEmbedder(documents: { $0.map { vector($0, dim: dim) } }, query: { vector($0, dim: dim) })
    }

    static func failing() -> KnowledgeEmbedder {
        KnowledgeEmbedder(documents: { _ in throw KnowledgeError.noEmbedder },
                          query: { _ in throw KnowledgeError.noEmbedder })
    }

    final class FlakySwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var _failing = true
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); defer { lock.unlock() }; _failing = newValue }
        }
    }

    /// Fails while `switch.failing` is true, then behaves like `embedder()`.
    static func flaky() -> (KnowledgeEmbedder, FlakySwitch) {
        let sw = FlakySwitch()
        let e = KnowledgeEmbedder(
            documents: { texts in if sw.failing { throw KnowledgeError.noEmbedder }; return texts.map { vector($0) } },
            query: { t in if sw.failing { throw KnowledgeError.noEmbedder }; return vector(t) })
        return (e, sw)
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("knowledge.db")
    }
}
