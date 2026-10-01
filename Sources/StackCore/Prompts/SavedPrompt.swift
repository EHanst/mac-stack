import Foundation

/// One prompt in the library: something the user saved or a starter that shipped with the app.
public struct SavedPrompt: Codable, Sendable, Identifiable, Equatable {

    public enum Scope: String, Codable, Sendable { case global, workspace }

    /// An earlier title/body, kept so an edit can be undone.
    public struct Version: Codable, Sendable, Equatable {
        public var date: Date
        public var title: String
        public var body: String
    }

    public var id: String
    public var scope: Scope
    public var title: String
    public var body: String
    public var tags: [String]
    /// Short name to look it up by, e.g. `review`. Lower-case letters, digits, `-`, `_`.
    public var slash: String?
    public var pinned: Bool
    /// Shipped with the app (can be edited and reset).
    public var builtIn: Bool
    /// Alternative bodies for particular models, keyed by profile family (see `ModelPromptProfile`).
    public var modelVariants: [String: String]
    public var versions: [Version]
    public var useCount: Int
    public var lastUsed: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public static let maxVersions = 20

    public init(
        id: String = UUID().uuidString, scope: Scope = .global,
        title: String, body: String, tags: [String] = [], slash: String? = nil,
        pinned: Bool = false, builtIn: Bool = false,
        modelVariants: [String: String] = [:], now: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.title = title
        self.body = body
        self.tags = tags
        self.slash = slash.flatMap(Self.cleanSlash)
        self.pinned = pinned
        self.builtIn = builtIn
        self.modelVariants = modelVariants
        self.versions = []
        self.useCount = 0
        self.lastUsed = nil
        self.createdAt = now
        self.updatedAt = now
    }

    /// The body to use for a model family: its variant if there is one, else the main body.
    public func body(forFamily family: String?) -> String {
        family.flatMap { modelVariants[$0] } ?? body
    }

    public static func cleanSlash(_ raw: String) -> String? {
        let lowered = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let cleaned = String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" })
        return cleaned.isEmpty ? nil : cleaned
    }
}
