import Testing
import Foundation
@testable import KororoCore
@testable import StackCore
@testable import StackMCP

@Suite("ContextBudget")
struct ContextBudgetTests {

    private let gib = 1 << 30
    private let weights = Int(7.14 * Double(1 << 30))
    private let b = ContextBudget.bonsai27B2bit

    private func tokens(_ v: ContextBudget.Verdict) -> Int {
        switch v { case .ok(let n), .belowFloor(let n): n }
    }

    @Test("predictions are never below what KororoBench measured on the corrected model (chunk 128, M3 Pro 18 GB)")
    func conservativeAgainstMeasurements() {
        let measured: [(tokens: Int, overGiB: Double)] = [(1042, 1.45), (2087, 1.57), (4175, 1.92), (8419, 2.46)]
        for m in measured {
            let predicted = b.predictedPeakBytes(weightBytes: weights, promptTokens: m.tokens) - weights
            #expect(Double(predicted) >= m.overGiB * Double(gib), "\(m.tokens) tokens")
            #expect(Double(predicted) <= m.overGiB * Double(gib) * 1.15, "\(m.tokens) tokens too pessimistic")
        }
    }

    @Test("this Mac (13.3 GiB working set) gets a usable context")
    func measuredMachine() {
        let v = b.verdict(workingSetBytes: Int(13.32 * Double(gib)), weightBytes: weights)
        guard case .ok(let n) = v else { Issue.record("expected .ok"); return }
        #expect(n > 8_421)          // we measured 8.4k fitting comfortably
    }

    @Test("a small working set is below the floor and asks for cloud-only")
    func belowFloor() {
        let v = b.verdict(workingSetBytes: 9 * gib, weightBytes: weights)
        guard case .belowFloor = v else { Issue.record("expected .belowFloor"); return }
    }

    @Test("limit grows monotonically with working set and is capped at the context window")
    func monotonicAndCapped() {
        var last = 0
        for ws in stride(from: 10, through: 40, by: 2) {
            let n = tokens(b.verdict(workingSetBytes: ws * gib, weightBytes: weights))
            #expect(n >= last)
            last = n
        }
        #expect(last == b.contextWindow)
    }

    @Test("memory held by other apps (less available) lowers the limit")
    func otherAppsShrinkBudget() {
        let ws = Int(13.32 * Double(gib))
        let free = tokens(b.verdict(workingSetBytes: ws, weightBytes: weights,
                                    currentActiveBytes: weights, availableSystemBytes: 8 * gib))
        let contended = tokens(b.verdict(workingSetBytes: ws, weightBytes: weights,
                                         currentActiveBytes: weights, availableSystemBytes: 2 * gib))
        #expect(contended < free)
    }

    @Test("before load, the weights themselves must fit in available memory")
    func notLoadedNeedsWeights() {
        let v = b.verdict(workingSetBytes: 13 * gib, weightBytes: weights,
                          currentActiveBytes: 0, availableSystemBytes: 5 * gib)
        guard case .belowFloor = v else { Issue.record("expected .belowFloor"); return }
    }

    @Test("memory reserved for other resident models lowers the limit")
    func reservedBytes() {
        var reserved = b
        reserved.reservedBytes = 1 * gib
        let ws = Int(13.32 * Double(gib))
        #expect(tokens(reserved.verdict(workingSetBytes: ws, weightBytes: weights))
                < tokens(b.verdict(workingSetBytes: ws, weightBytes: weights)))
    }
}

@Suite struct ContextBudgetModelSelectionTests {
    private func directory(config: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func recognisesTheMeasured4B() throws {
        let dir = try directory(config: #"{"text_config": {"num_hidden_layers": 32, "hidden_size": 2560}}"#)
        #expect(ContextBudget.forModel(at: dir) == .qwen35_4b)
    }

    @Test func unknownShapesAndMissingConfigsGetTheConservativeBudget() throws {
        let other = try directory(config: #"{"num_hidden_layers": 64, "hidden_size": 5120}"#)
        #expect(ContextBudget.forModel(at: other) == .bonsai27B2bit)
        #expect(ContextBudget.forModel(at: URL(fileURLWithPath: "/nonexistent")) == .bonsai27B2bit)
    }

    @Test func the4BFitsALongContextOnA16GBMacAndAUsefulOneOn8() {
        let weights = 3_300_000_000
        func tokens(_ ramGB: Int) -> Int {
            switch ContextBudget.qwen35_4b.verdict(workingSetBytes: ramGB * 1_073_741_824 * 74 / 100, weightBytes: weights) {
            case .ok(let n), .belowFloor(let n): n
            }
        }
        #expect(tokens(16) == 64_000)
        #expect(tokens(8) > 8_000)
    }
}
