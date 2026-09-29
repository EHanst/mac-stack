import Foundation

public enum BoundaryError: LocalizedError, Equatable {
    case pathTraversal(String)
    case outsideWorkspace(String)
    case disallowedExtension(String)
    case disallowedCommand(String)

    public var errorDescription: String? {
        switch self {
        case .pathTraversal(let p): "Path traversal attempt: \(p)"
        case .outsideWorkspace(let p): "Path outside workspace: \(p)"
        case .disallowedExtension(let e): "File extension not allowed: \(e)"
        case .disallowedCommand(let c): "Command not allowed: \(c)"
        }
    }
}

public struct WorkspaceBoundary: Sendable {
    public let context: WorkspaceContext

    public init(context: WorkspaceContext) {
        self.context = context
    }

    public func validateRead(_ url: URL) throws {
        try validateContainment(url)
    }

    public func validateWrite(_ url: URL) throws {
        try validateContainment(url)
        let ext = url.pathExtension
        guard ext.isEmpty || context.policy.allowedExtensions.contains(ext) else {
            throw BoundaryError.disallowedExtension(ext)
        }
    }

    public func validateExecution(_ command: String) throws {
        let executable = command.components(separatedBy: " ").first ?? command
        let allowed = context.policy.executablePrefixes.contains { executable.hasPrefix($0) }
        guard allowed else { throw BoundaryError.disallowedCommand(executable) }
    }

    // MARK: - Private

    private func validateContainment(_ url: URL) throws {
        let inputPath = url.standardized.path

        // Reject raw ".." components before resolution
        if inputPath.contains("/../") || inputPath.hasSuffix("/..") {
            throw BoundaryError.pathTraversal(inputPath)
        }

        // Resolve symlinks to catch escapes
        let resolved = url.resolvingSymlinksInPath().standardized
        let rootResolved = context.root.resolvingSymlinksInPath().standardized
        let rootPath = rootResolved.path.hasSuffix("/") ? rootResolved.path : rootResolved.path + "/"

        guard resolved.path.hasPrefix(rootPath) || resolved.path == rootResolved.path else {
            if inputPath.contains("..") {
                throw BoundaryError.pathTraversal(inputPath)
            }
            throw BoundaryError.outsideWorkspace(resolved.path)
        }
    }
}
