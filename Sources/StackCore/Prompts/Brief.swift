import Foundation

private struct LegacySection: Codable {
    var kind: String
    var text: String
    var enabled: Bool
}

private struct LegacyVersion: Codable {
    var date: Date
    var sections: [LegacySection]
}

/// A piece of repo context attached to a brief. `text` is what gets inlined; `ref` is what a
/// tool that can read the repo itself is pointed at instead.
public struct ContextItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case file, symbol, gitDiff, snippet }
    public var id: String
    public var kind: Kind
    public var ref: String
    public var text: String
    public var mode: ContextMode
    public var tokens: Int
    public var included: Bool
    /// Where it came from, e.g. "search: login timeout". Shown to the user; never sent.
    public var provenance: String
    /// Higher is kept longer when the brief is over budget.
    public var priority: Int

    public init(id: String = UUID().uuidString, kind: Kind, ref: String, text: String,
                mode: ContextMode, tokens: Int? = nil, included: Bool = true,
                provenance: String = "", priority: Int = 0) {
        self.id = id; self.kind = kind; self.ref = ref; self.text = text; self.mode = mode
        self.tokens = tokens ?? PromptTokens.estimate(text)
        self.included = included; self.provenance = provenance; self.priority = priority
    }
}

public struct Brief: Codable, Sendable, Equatable, Identifiable {
    public struct Version: Codable, Sendable, Equatable {
        public var date: Date
        public var input: String
        public var body: String?

        public init(date: Date, input: String, body: String?) {
            self.date = date
            self.input = input
            self.body = body
        }
    }

    public static let currentVersion = 2
    public static let maxVersions = 20

    public var id: String
    public var schemaVersion: Int
    public var title: String
    public var workspace: String?
    public var target: TargetProfile
    public var input: String
    public var body: String?
    public var contextItems: [ContextItem]
    public var versions: [Version]
    public var createdAt: Date
    public var updatedAt: Date
    /// Auto-saved working revision from an open Improve workspace. Never shown as the brief body.
    public var draft: String?

    public var effectiveBody: String { BriefText.stripStrayTags(body ?? input) }
    public var isEdited: Bool { body != nil }
    public var isDraft: Bool { draft != nil }

    public init(id: String, schemaVersion: Int, title: String, workspace: String?, target: TargetProfile,
                input: String, body: String?, contextItems: [ContextItem],
                versions: [Version], createdAt: Date, updatedAt: Date, draft: String? = nil) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.workspace = workspace
        self.target = target
        self.input = input
        self.body = body
        self.contextItems = contextItems
        self.versions = versions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.draft = draft
    }

    public static func new(title: String, input: String = "", target: TargetProfile,
                           workspace: String? = nil, now: Date = Date()) -> Brief {
        Brief(id: UUID().uuidString, schemaVersion: currentVersion, title: title, workspace: workspace,
              target: target, input: input, body: nil,
              contextItems: [], versions: [], createdAt: now, updatedAt: now)
    }

    public mutating func snapshot(now: Date = Date()) {
        versions.append(Version(date: now, input: input, body: body))
        if versions.count > Self.maxVersions { versions.removeFirst(versions.count - Self.maxVersions) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, title, workspace, target
        case input, body, draft, contextItems, versions, createdAt, updatedAt
        case sections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        title = try c.decode(String.self, forKey: .title)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        target = try c.decode(TargetProfile.self, forKey: .target)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        contextItems = try c.decodeIfPresent([ContextItem].self, forKey: .contextItems) ?? []
        draft = try c.decodeIfPresent(String.self, forKey: .draft)

        if schemaVersion <= 1 {
            let legacySections = try c.decodeIfPresent([LegacySection].self, forKey: .sections) ?? []
            let legacyVersions = try c.decodeIfPresent([LegacyVersion].self, forKey: .versions) ?? []
            input = Self.joinLegacy(legacySections)
            body = nil
            // The old context section's switch also gated the attached items; keep them off.
            if legacySections.first(where: { $0.kind == "context" })?.enabled == false {
                for i in contextItems.indices { contextItems[i].included = false }
            }
            versions = legacyVersions.map {
                Version(date: $0.date, input: Self.joinLegacy($0.sections), body: nil)
            }
            self.schemaVersion = Self.currentVersion
        } else {
            input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
            body = try c.decodeIfPresent(String.self, forKey: .body)
            versions = try c.decodeIfPresent([Version].self, forKey: .versions) ?? []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(workspace, forKey: .workspace)
        try c.encode(target, forKey: .target)
        try c.encode(input, forKey: .input)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(draft, forKey: .draft)
        try c.encode(contextItems, forKey: .contextItems)
        try c.encode(versions, forKey: .versions)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    private static func joinLegacy(_ sections: [LegacySection]) -> String {
        let titles = [
            "goal": "Goal",
            "context": "Context",
            "constraints": "Constraints",
            "examples": "Examples",
            "outputFormat": "Output format"
        ]
        let order = ["goal", "context", "constraints", "examples", "outputFormat"]
        var parts: [String] = []
        for key in order {
            guard let section = sections.first(where: { $0.kind == key }), section.enabled else { continue }
            let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            parts.append("## \(titles[key] ?? key)\n\(text)")
        }
        return parts.joined(separator: "\n\n")
    }
}
