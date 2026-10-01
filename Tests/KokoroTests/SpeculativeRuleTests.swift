import Testing
@testable import StackCore

@Suite("SpeculativeRule")
struct SpeculativeRuleTests {
    private let dist: SpeculativeRule.Distribution = ([10, 20, 30, 40], [0.5, 0.3, 0.15, 0.05])

    /// One speculative step with a draft fixed at `draft`: accept it, else draw from the rest.
    private func step(draft: Int, rng: inout SystemRandomNumberGenerator) -> Int {
        let accept = Float.random(in: 0 ..< 1, using: &rng) < SpeculativeRule.acceptanceProbability(draft: draft, in: dist)
        return accept ? draft : SpeculativeRule.draw(dist, excluding: draft, u: Float.random(in: 0 ..< 1, using: &rng))
    }

    @Test("accept-or-redraw reproduces the target distribution whichever token is drafted")
    func preservesDistribution() {
        var rng = SystemRandomNumberGenerator()
        for draft in [10, 20, 40, 99] {          // 99 is outside the candidate set
            var counts: [Int: Int] = [:]
            let n = 60_000
            for _ in 0..<n { counts[step(draft: draft, rng: &rng), default: 0] += 1 }
            for (i, id) in dist.candidates.enumerated() {
                let got = Double(counts[Int(id)] ?? 0) / Double(n)
                #expect(abs(got - Double(dist.probs[i])) < 0.01, "draft \(draft), token \(id): \(got)")
            }
        }
    }

    @Test("a draft outside the candidates is never accepted; a certain draft always is")
    func edges() {
        #expect(SpeculativeRule.acceptanceProbability(draft: 99, in: dist) == 0)
        #expect(SpeculativeRule.acceptanceProbability(draft: 7, in: ([7], [1])) == 1)
    }

    @Test("draw with everything excluded falls back to the top candidate")
    func degenerate() {
        #expect(SpeculativeRule.draw(([7], [1]), excluding: 7, u: 0.5) == 7)
    }
}
