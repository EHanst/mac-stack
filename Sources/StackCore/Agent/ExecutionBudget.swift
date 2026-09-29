import Foundation

public struct ExecutionBudget: Sendable {
    public let maxRetries: Int
    public let totalDuration: Duration
    public let buildDuration: Duration
    public let maxModifiedFiles: Int
    public let maxDiffBytes: Int

    public init(maxRetries: Int, totalDuration: Duration, buildDuration: Duration,
                maxModifiedFiles: Int, maxDiffBytes: Int) {
        self.maxRetries = maxRetries
        self.totalDuration = totalDuration
        self.buildDuration = buildDuration
        self.maxModifiedFiles = maxModifiedFiles
        self.maxDiffBytes = maxDiffBytes
    }

    public static let `default` = ExecutionBudget(
        maxRetries: 5,
        totalDuration: .seconds(300),
        buildDuration: .seconds(120),
        maxModifiedFiles: 20,
        maxDiffBytes: 500_000
    )
}

public enum BudgetExceeded: Error, Sendable {
    case maxRetriesExceeded
    case totalDurationExceeded
    case buildDurationExceeded
    case tooManyModifiedFiles
    case diffTooLarge
}

public struct ExecutionBudgetTracker: Sendable {
    public let budget: ExecutionBudget
    private var retryCount: Int = 0
    private var totalElapsed: Duration = .zero
    private var buildElapsed: Duration = .zero

    public init(budget: ExecutionBudget) {
        self.budget = budget
    }

    public mutating func recordRetry() throws {
        retryCount += 1
        if retryCount > budget.maxRetries {
            throw BudgetExceeded.maxRetriesExceeded
        }
    }

    public mutating func recordBuildTime(_ d: Duration) throws {
        buildElapsed += d
        if buildElapsed > budget.buildDuration {
            throw BudgetExceeded.buildDurationExceeded
        }
    }

    public mutating func recordElapsed(_ d: Duration) throws {
        totalElapsed += d
        if totalElapsed > budget.totalDuration {
            throw BudgetExceeded.totalDurationExceeded
        }
    }

    public func checkModifiedFiles(_ count: Int) throws {
        if count > budget.maxModifiedFiles {
            throw BudgetExceeded.tooManyModifiedFiles
        }
    }

    public func checkDiffSize(_ bytes: Int) throws {
        if bytes > budget.maxDiffBytes {
            throw BudgetExceeded.diffTooLarge
        }
    }
}
