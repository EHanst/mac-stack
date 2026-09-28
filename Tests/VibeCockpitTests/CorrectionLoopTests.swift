import Testing
@testable import VibeCockpitCore

@Suite("CorrectionLoop")
struct CorrectionLoopTests {

    @Test("retries up to maxRetries distinct errors")
    func retriesDistinctErrors() {
        var state = CorrectionLoopState(maxRetries: 3)
        for i in 0..<3 {
            let result = BuildResult(exitCode: 1, stdout: "", stderr: "error \(i)", duration: .zero)
            let (action, next) = state.next(given: result)
            state = next
            guard case .retry = action else {
                Issue.record("Expected .retry on attempt \(i)")
                return
            }
        }
        let finalResult = BuildResult(exitCode: 1, stdout: "", stderr: "error 99", duration: .zero)
        let (action, _) = state.next(given: finalResult)
        guard case .surfaceToUser(let reason) = action,
              case .maxRetriesExceeded = reason else {
            Issue.record("Expected .surfaceToUser(.maxRetriesExceeded)")
            return
        }
    }

    @Test("halts immediately on repeated identical error")
    func haltsOnRepeatedError() {
        var state = CorrectionLoopState(maxRetries: 3)
        let result = BuildResult(exitCode: 1, stdout: "", stderr: "same error", duration: .zero)
        let (_, next) = state.next(given: result)
        state = next
        let (action, _) = state.next(given: result)
        guard case .surfaceToUser(let reason) = action,
              case .repeatedIdenticalError = reason else {
            Issue.record("Expected .surfaceToUser(.repeatedIdenticalError)")
            return
        }
    }

    @Test("pure — same input produces same output")
    func purity() {
        let state = CorrectionLoopState(maxRetries: 2)
        let result = BuildResult(exitCode: 1, stdout: "", stderr: "err", duration: .zero)
        let (action1, next1) = state.next(given: result)
        let (action2, next2) = state.next(given: result)
        guard case .retry = action1, case .retry = action2 else {
            Issue.record("Expected retry")
            return
        }
        #expect(next1.attemptCount == next2.attemptCount)
    }
}
