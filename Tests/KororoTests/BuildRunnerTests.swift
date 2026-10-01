import Testing
import Foundation
@testable import StackCore

@Suite("BuildRunner")
struct BuildRunnerTests {
    private let dir = FileManager.default.temporaryDirectory

    @Test("captures output and exit code")
    func captures() async throws {
        let r = try await BuildRunner().run(command: "echo hi; echo oops >&2; exit 3", workingDirectory: dir)
        #expect(r.stdout == "hi\n" && r.stderr == "oops\n" && r.exitCode == 3 && !r.succeeded)
    }

    @Test("a command that outlives the timeout is stopped")
    func timesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: BuildRunner.RunnerError.self) {
            _ = try await BuildRunner().run(command: "sleep 30", workingDirectory: dir, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }
}

@Suite("BuildRunner output")
struct BuildRunnerOutputTests {
    @Test("large output does not stall the command")
    func largeOutput() async throws {
        let r = try await BuildRunner().run(command: "head -c 400000 /dev/zero | tr '\\0' x", workingDirectory: FileManager.default.temporaryDirectory, timeout: .seconds(20))
        #expect(r.stdout.count == 400_000)
    }
}
