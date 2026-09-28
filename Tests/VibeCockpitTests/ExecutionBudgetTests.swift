import Testing
@testable import VibeCockpitCore

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
}
