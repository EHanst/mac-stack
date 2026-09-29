import Testing
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("ExecutionBudget")
struct ExecutionBudgetTests {

    @Test("recordRetry throws after maxRetries exceeded")
    func retryLimit() throws {
        var tracker = ExecutionBudgetTracker(budget: ExecutionBudget(
            maxRetries: 2, totalDuration: .seconds(300),
            buildDuration: .seconds(120), maxModifiedFiles: 20, maxDiffBytes: 500_000))
        try tracker.recordRetry()
        try tracker.recordRetry()
        #expect(throws: BudgetExceeded.self) { try tracker.recordRetry() }
    }

    @Test("checkModifiedFiles throws when over limit")
    func fileCountLimit() throws {
        let tracker = ExecutionBudgetTracker(budget: ExecutionBudget(
            maxRetries: 5, totalDuration: .seconds(300),
            buildDuration: .seconds(120), maxModifiedFiles: 5, maxDiffBytes: 500_000))
        try tracker.checkModifiedFiles(5)
        #expect(throws: BudgetExceeded.self) { try tracker.checkModifiedFiles(6) }
    }

    @Test("recordElapsed throws after totalDuration")
    func totalDurationLimit() throws {
        var tracker = ExecutionBudgetTracker(budget: ExecutionBudget(
            maxRetries: 5, totalDuration: .seconds(10),
            buildDuration: .seconds(120), maxModifiedFiles: 20, maxDiffBytes: 500_000))
        try tracker.recordElapsed(.seconds(9))
        #expect(throws: BudgetExceeded.self) { try tracker.recordElapsed(.seconds(2)) }
    }

    @Test("recordBuildTime throws after buildDuration exceeded")
    func buildDurationLimit() throws {
        var tracker = ExecutionBudgetTracker(budget: ExecutionBudget(
            maxRetries: 5, totalDuration: .seconds(300),
            buildDuration: .seconds(60), maxModifiedFiles: 20, maxDiffBytes: 500_000))
        try tracker.recordBuildTime(.seconds(59))
        #expect(throws: BudgetExceeded.self) { try tracker.recordBuildTime(.seconds(2)) }
    }

    @Test("recordBuildTime accumulates across calls")
    func buildDurationAccumulates() throws {
        var tracker = ExecutionBudgetTracker(budget: ExecutionBudget(
            maxRetries: 5, totalDuration: .seconds(300),
            buildDuration: .seconds(30), maxModifiedFiles: 20, maxDiffBytes: 500_000))
        try tracker.recordBuildTime(.seconds(10))
        try tracker.recordBuildTime(.seconds(10))
        try tracker.recordBuildTime(.seconds(10))
        // Exactly at limit: 30s == 30s (not exceeded)
        // One more millisecond pushes it over
        #expect(throws: BudgetExceeded.self) { try tracker.recordBuildTime(.milliseconds(1)) }
    }

    @Test("checkDiffSize throws when over limit")
    func diffSizeLimit() throws {
        let tracker = ExecutionBudgetTracker(budget: ExecutionBudget(
            maxRetries: 5, totalDuration: .seconds(300),
            buildDuration: .seconds(120), maxModifiedFiles: 20, maxDiffBytes: 1_000))
        try tracker.checkDiffSize(1_000)
        #expect(throws: BudgetExceeded.self) { try tracker.checkDiffSize(1_001) }
    }

    @Test("checkDiffSize allows exactly at limit")
    func diffSizeAtLimit() throws {
        let tracker = ExecutionBudgetTracker(budget: ExecutionBudget(
            maxRetries: 5, totalDuration: .seconds(300),
            buildDuration: .seconds(120), maxModifiedFiles: 20, maxDiffBytes: 500_000))
        try tracker.checkDiffSize(500_000)
    }

    @Test("default budget has expected values")
    func defaultBudget() {
        let b = ExecutionBudget.default
        #expect(b.maxRetries == 5)
        #expect(b.maxModifiedFiles == 20)
        #expect(b.maxDiffBytes == 500_000)
    }
}
