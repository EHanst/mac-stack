import Foundation
import Crypto

/// Pure functional correction loop state. No mutation — `next()` returns a new state.
/// Testable without mocks: the reducer is a pure function.
public struct CorrectionLoopState: Sendable {

    public enum Action: Sendable {
        case retry
        case surfaceToUser(HaltReason)
    }

    public enum HaltReason: Sendable, CustomStringConvertible {
        case maxRetriesExceeded(Int)
        case repeatedIdenticalError
        case cancelled

        public var description: String {
            switch self {
            case .maxRetriesExceeded(let n): "Maximum of \(n) retries exceeded."
            case .repeatedIdenticalError: "Identical error repeated — unable to auto-correct."
            case .cancelled: "Correction loop cancelled."
            }
        }
    }

    public let maxRetries: Int
    private let attempts: [Data]   // SHA-256 hashes of compiler stderr

    public init(maxRetries: Int) {
        self.maxRetries = maxRetries
        self.attempts = []
    }

    private init(maxRetries: Int, attempts: [Data]) {
        self.maxRetries = maxRetries
        self.attempts = attempts
    }

    /// Given a build result, decide whether to retry or surface to the user.
    /// Returns an (Action, new state) pair — the new state must be used for the next call.
    public func next(given result: BuildResult) -> (Action, CorrectionLoopState) {
        let hash = Data(SHA256.hash(data: Data(result.stderr.utf8)))
        if attempts.contains(hash) {
            return (.surfaceToUser(.repeatedIdenticalError), self)
        }
        if attempts.count >= maxRetries {
            return (.surfaceToUser(.maxRetriesExceeded(maxRetries)), self)
        }
        return (.retry, CorrectionLoopState(maxRetries: maxRetries, attempts: attempts + [hash]))
    }

    public var attemptCount: Int { attempts.count }
    public var hasAttempts: Bool { !attempts.isEmpty }
}
