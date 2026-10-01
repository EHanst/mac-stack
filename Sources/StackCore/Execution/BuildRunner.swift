import Foundation

public struct BuildResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let duration: Duration

    public var succeeded: Bool { exitCode == 0 }
}

/// Runs a shell command as a subprocess and captures its output. Used by the MCP build tool.
public actor BuildRunner {

    public enum RunnerError: LocalizedError {
        case timeout(Duration)

        public var errorDescription: String? {
            switch self {
            case .timeout(let d): "Build timed out after \(d)."
            }
        }
    }

    public init() {}

    public func run(
        command: String,
        workingDirectory: URL,
        environment: [String: String] = [:],
        timeout: Duration = .seconds(120)
    ) async throws -> BuildResult {
        let start = ContinuousClock.now
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes while it runs, so a chatty command can't fill a pipe and stall; stop it at the deadline.
        let out = Drain(stdoutPipe.fileHandleForReading)
        let err = Drain(stderrPipe.fileHandleForReading)
        let timedOut = TimeoutFlag()
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            timedOut.set()
            if process.isRunning { process.terminate() }
        }
        let result: BuildResult = await withCheckedContinuation { cont in
            process.terminationHandler = { p in
                let elapsed = ContinuousClock.now - start
                cont.resume(returning: BuildResult(exitCode: p.terminationStatus,
                                                   stdout: out.finish(), stderr: err.finish(), duration: elapsed))
            }
        }
        watchdog.cancel()
        if timedOut.value { throw RunnerError.timeout(timeout) }
        return result
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// Collects everything a pipe produces as it arrives.
private final class Drain: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            self?.lock.withLock { self?.data.append(chunk) }
        }
    }

    /// Stops the handler and returns the text, including anything still unread.
    func finish() -> String {
        handle.readabilityHandler = nil
        let rest = handle.readDataToEndOfFile()
        return lock.withLock { String(data: data + rest, encoding: .utf8) ?? "" }
    }
}
