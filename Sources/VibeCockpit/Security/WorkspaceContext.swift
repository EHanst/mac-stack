import Foundation

public struct WorkspaceID: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct WorkspacePolicy: Sendable {
    public var allowedExtensions: Set<String>
    public var executablePrefixes: [String]

    public init(allowedExtensions: Set<String>, executablePrefixes: [String]) {
        self.allowedExtensions = allowedExtensions
        self.executablePrefixes = executablePrefixes
    }

    public static let `default` = WorkspacePolicy(
        allowedExtensions: ["swift", "json", "md", "yaml", "yml", "txt", "xcconfig", "plist"],
        executablePrefixes: ["swift", "xcodebuild", "xcrun", "git"]
    )
}

public struct WorkspaceContext: Sendable {
    public let root: URL
    public let workspaceID: WorkspaceID
    public let policy: WorkspacePolicy

    public init(root: URL, workspaceID: WorkspaceID, policy: WorkspacePolicy) {
        self.root = root
        self.workspaceID = workspaceID
        self.policy = policy
    }
}
