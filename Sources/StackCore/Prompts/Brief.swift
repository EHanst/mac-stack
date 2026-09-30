import Foundation

public struct BriefSection: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case goal, context, constraints, examples, outputFormat }
    public var kind: Kind
    public var text: String
    public var enabled: Bool
    public var id: Kind { kind }
    public init(kind: Kind, text: String = "", enabled: Bool = true) {
        self.kind = kind; self.text = text; self.enabled = enabled
    }
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
        public var sections: [BriefSection]
    }

    public static let currentVersion = 1
    public static let maxVersions = 20

    public var id: String
    public var schemaVersion: Int
    public var title: String
    public var workspace: String?
    public var target: TargetProfile
    public var sections: [BriefSection]
    public var contextItems: [ContextItem]
    public var versions: [Version]
    public var createdAt: Date
    public var updatedAt: Date

    public static func new(title: String, target: TargetProfile, workspace: String? = nil, now: Date = Date()) -> Brief {
        Brief(id: UUID().uuidString, schemaVersion: currentVersion, title: title, workspace: workspace,
              target: target, sections: BriefSection.Kind.allCases.map { BriefSection(kind: $0) },
              contextItems: [], versions: [], createdAt: now, updatedAt: now)
    }

    public func text(of kind: BriefSection.Kind) -> String {
        sections.first { $0.kind == kind }?.text ?? ""
    }

    public mutating func setText(_ text: String, for kind: BriefSection.Kind, now: Date = Date()) {
        if let i = sections.firstIndex(where: { $0.kind == kind }) {
            sections[i].text = text
        } else {
            sections.append(BriefSection(kind: kind, text: text))
        }
        updatedAt = now
    }

    /// Records the current sections so an edit can be undone or diffed, newest last.
    public mutating func snapshot(now: Date = Date()) {
        versions.append(Version(date: now, sections: sections))
        if versions.count > Self.maxVersions { versions.removeFirst(versions.count - Self.maxVersions) }
    }
}
