import Foundation
import os

public struct BuildResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let duration: Duration

    public var succeeded: Bool { exitCode == 0 }
}

/// Runs build commands through the BuildRunnerXPCService.
/// Falls back to direct subprocess execution when XPC service is unavailable
/// (e.g., running without a full Xcode build / app bundle).
public actor XPCBuildRunner {

    private var connection: NSXPCConnection?
    private let logger = Logger(subsystem: "com.vibecockpit", category: "XPCBuildRunner")
    private let healthCheckInterval: Duration = .seconds(30)
    private var healthCheckTask: Task<Void, Never>?

    public enum RunnerError: LocalizedError {
        case timeout(Duration)
        case connectionInvalid
        case executionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .timeout(let d): "Build timed out after \(d)."
            case .connectionInvalid: "XPC connection is invalid."
            case .executionFailed(let msg): "Execution failed: \(msg)"
            }
        }
    }

    public init() {}

    public func connect() {
        let conn = NSXPCConnection(machServiceName: "com.vibecockpit.buildrunner",
                                   options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: BuildRunnerXPCProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { await self?.handleInvalidation() }
        }
        conn.interruptionHandler = { [weak self] in
            Task { await self?.handleInterruption() }
        }
        conn.resume()
        connection = conn
        startHealthCheck()
        logger.info("XPC connection established.")
    }

    public func run(
        command: String,
        workingDirectory: URL,
        environment: [String: String] = [:],
        timeout: Duration = .seconds(120)
    ) async throws -> BuildResult {
        // When running outside a full app bundle, fall back to direct subprocess.
        if connection == nil {
            return try await runDirectly(
                command: command,
                workingDirectory: workingDirectory,
                environment: environment,
                timeout: timeout
            )
        }
        return try await runViaXPC(
            command: command,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
    }

    public func cancel() async {
        connection?.invalidate()
        connection = nil
        healthCheckTask?.cancel()
    }

    // MARK: - XPC path

    private func runViaXPC(
        command: String,
        workingDirectory: URL,
        environment: [String: String],
        timeout: Duration
    ) async throws -> BuildResult {
        guard let conn = connection else { throw RunnerError.connectionInvalid }
        guard let proxy = conn.remoteObjectProxy as? BuildRunnerXPCProtocol else {
            throw RunnerError.connectionInvalid
        }
        let env = environment.merging(ProcessInfo.processInfo.environment) { lhs, _ in lhs }
        let workDir = workingDirectory.path
        let xpcResult: BuildResult = try await withCheckedThrowingContinuation { continuation in
            proxy.run(command: command, workingDirectory: workDir, environment: env) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let result = data.flatMap { try? JSONDecoder().decode(BuildResult.self, from: $0) }
                    ?? BuildResult(exitCode: -1, stdout: "", stderr: "No XPC response", duration: .zero)
                continuation.resume(returning: result)
            }
        }
        return xpcResult
    }

    // MARK: - Direct subprocess fallback (dev / CLI builds)

    private func runDirectly(
        command: String,
        workingDirectory: URL,
        environment: [String: String],
        timeout: Duration
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

        let result: BuildResult = await withCheckedContinuation { cont in
            process.terminationHandler = { p in
                let elapsed = ContinuousClock.now - start
                let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: BuildResult(exitCode: p.terminationStatus,
                                                   stdout: out, stderr: err, duration: elapsed))
            }
        }

        if ContinuousClock.now - start >= timeout {
            throw RunnerError.timeout(timeout)
        }
        return result
    }

    // MARK: - Health check

    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: healthCheckInterval)
                if Task.isCancelled { break }
                if connection == nil { connect() }
            }
        }
    }

    private func handleInvalidation() {
        logger.warning("XPC connection invalidated. Will reconnect on next request.")
        connection = nil
    }

    private func handleInterruption() {
        logger.warning("XPC connection interrupted. Reconnecting...")
        connection = nil
        connect()
    }
}

// MARK: - XPC Protocol

@objc public protocol BuildRunnerXPCProtocol {
    func run(command: String, workingDirectory: String,
             environment: [String: String],
             reply: @escaping (Data?, Error?) -> Void)
}

extension BuildResult: Codable {
    enum CodingKeys: String, CodingKey { case exitCode, stdout, stderr, durationSeconds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exitCode = try c.decode(Int32.self, forKey: .exitCode)
        stdout = try c.decode(String.self, forKey: .stdout)
        stderr = try c.decode(String.self, forKey: .stderr)
        let secs = try c.decodeIfPresent(Int64.self, forKey: .durationSeconds) ?? 0
        duration = Duration(secondsComponent: secs, attosecondsComponent: 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exitCode, forKey: .exitCode)
        try c.encode(stdout, forKey: .stdout)
        try c.encode(stderr, forKey: .stderr)
        try c.encode(duration.components.seconds, forKey: .durationSeconds)
    }
}
