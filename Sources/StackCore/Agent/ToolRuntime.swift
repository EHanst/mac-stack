import Foundation

public actor ToolRuntime {

    private let boundary: WorkspaceBoundary
    private let buildRunner: BuildRunner
    private let gitManager: GitSnapshotManager
    private let pipeline: IndexingPipeline
    private var activeTasks: [OperationID: Task<Void, Error>] = [:]

    public nonisolated var workspaceRoot: URL { boundary.context.root }

    public init(
        boundary: WorkspaceBoundary,
        buildRunner: BuildRunner,
        gitManager: GitSnapshotManager,
        pipeline: IndexingPipeline
    ) {
        self.boundary = boundary
        self.buildRunner = buildRunner
        self.gitManager = gitManager
        self.pipeline = pipeline
    }

    // MARK: - Tool Operations

    public func readFile(path: URL, startLine: Int?, endLine: Int?) async throws -> String {
        try boundary.validateRead(path)
        let text = try String(contentsOf: path, encoding: .utf8)
        guard startLine != nil || endLine != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        let start = (startLine.map { $0 - 1 }) ?? 0
        let end = (endLine.map { min($0 - 1, lines.count - 1) }) ?? (lines.count - 1)
        return (start <= end) ? lines[start...end].joined(separator: "\n") : text
    }

    public func writeFile(path: URL, content: String, createDirectories: Bool) async throws {
        try boundary.validateWrite(path)
        if createDirectories {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(content.utf8).write(to: path, options: .atomic)
    }

    public func runBuild(command: String, workingDirectory: URL, timeout: Duration) async throws -> BuildResult {
        try boundary.validateExecution(command)
        try boundary.validateRead(workingDirectory)
        return try await buildRunner.run(command: command, workingDirectory: workingDirectory, timeout: timeout)
    }

    public func gitSnapshot(message: String) async throws -> SnapshotRef {
        try await gitManager.createSnapshot(message: message)
    }

    public func indexWorkspace(_ url: URL) async throws {
        try boundary.validateRead(url)
        try await pipeline.reindexWorkspace(url)
    }

    // MARK: - Cancellation

    public func trackTask(_ id: OperationID, task: Task<Void, Error>) {
        activeTasks[id] = task
    }

    public func cancelOperation(_ id: OperationID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
    }

    public func removeTask(_ id: OperationID) {
        activeTasks.removeValue(forKey: id)
    }
}
