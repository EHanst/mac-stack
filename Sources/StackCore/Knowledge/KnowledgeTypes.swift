import Foundation

public enum KnowledgeKind: String, Codable, Sendable, CaseIterable {
    /// A curated prompt-engineering snippet.
    case technique
    /// A quirk of a target model family or surface.
    case targetNote
    /// An accepted brief: the sections the user settled on.
    case exemplar
    /// Phrasing for a verifiable constraint.
    case constraint
}

public struct KnowledgeEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: KnowledgeKind
    /// `TargetProfile.modelFamily`; nil applies to every target.
    public var target: String?
    /// nil for the user's own history; otherwise the id of the pack that seeded it.
    public var pack: String?
    public var text: String
    public var meta: [String: String]
    public var weight: Double
    public var enabled: Bool
    public var created: Date

    public init(id: String = UUID().uuidString, kind: KnowledgeKind, target: String? = nil, pack: String? = nil,
                text: String, meta: [String: String] = [:], weight: Double = 1, enabled: Bool = true,
                created: Date = Date()) {
        self.id = id; self.kind = kind; self.target = target; self.pack = pack; self.text = text
        self.meta = meta; self.weight = weight; self.enabled = enabled; self.created = created
    }
}

public struct KnowledgeHit: Sendable, Equatable {
    public let entry: KnowledgeEntry
    public let score: Double
    public init(entry: KnowledgeEntry, score: Double) { self.entry = entry; self.score = score }
}

public enum SignalOutcome: String, Codable, Sendable { case accepted, edited, rejected }

/// The local embedder as the store sees it. Two entry points because query and document prefixes differ.
public struct KnowledgeEmbedder: Sendable {
    public var documents: @Sendable ([String]) async throws -> [[Float]]
    public var query: @Sendable (String) async throws -> [Float]
    public init(documents: @escaping @Sendable ([String]) async throws -> [[Float]],
                query: @escaping @Sendable (String) async throws -> [Float]) {
        self.documents = documents; self.query = query
    }
}

public enum KnowledgeError: LocalizedError, Equatable {
    case openFailed(String)
    case queryFailed(String)
    case corrupt
    case noEmbedder
    case badPack(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): "Couldn't open the knowledge store: \(m)"
        case .queryFailed(let m): "Knowledge store error: \(m)"
        case .corrupt: "The knowledge store file was unreadable."
        case .noEmbedder: "The embedding model isn't available."
        case .badPack(let m): "That knowledge pack isn't usable: \(m)"
        }
    }
}

public enum KnowledgeLimits {
    public static let maxTextChars = 4000
    public static let weightRange: ClosedRange<Double> = 0.25...3.0
}
