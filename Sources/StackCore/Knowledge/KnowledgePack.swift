import Foundation

public struct KnowledgePackManifest: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var kind: KnowledgeKind
        public var target: String?
        public var text: String
        public var meta: [String: String]?
    }
    public var id: String
    public var name: String
    public var version: Int
    public var license: String
    public var attribution: String
    /// Inline entries, or `entriesFile` (JSON Lines of `Item`, relative to the manifest), or both.
    public var entries: [Item]?
    public var entriesFile: String?
}

/// Reads a pack directory (`manifest.json` plus an optional JSONL file) into a `KnowledgeStore`.
public enum KnowledgePackLoader {
    private static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,64}$")

    public static func load(directory: URL, into store: KnowledgeStore) async throws -> Int {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw KnowledgeError.badPack("manifest.json not found") }
        guard let manifest = try? JSONDecoder().decode(KnowledgePackManifest.self, from: data) else {
            throw KnowledgeError.badPack("manifest.json is not valid")
        }
        let range = NSRange(manifest.id.startIndex..., in: manifest.id)
        guard idPattern.firstMatch(in: manifest.id, range: range) != nil, manifest.id != ".", manifest.id != ".." else {
            throw KnowledgeError.badPack("the pack id may only use letters, digits, dot, dash and underscore")
        }

        var items = manifest.entries ?? []
        if let file = manifest.entriesFile {
            guard !file.contains("/"), !file.contains(".."),
                  let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else {
                throw KnowledgeError.badPack("entries file \(file) can't be read")
            }
            let decoder = JSONDecoder()
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let item = try? decoder.decode(KnowledgePackManifest.Item.self, from: Data(line.utf8)) { items.append(item) }
            }
        }

        var incoming: [KnowledgeEntry] = []
        for item in items {
            let text = String(item.text.prefix(KnowledgeLimits.maxTextChars))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let hash = KnowledgeStore.contentHash(pack: manifest.id, kind: item.kind, target: item.target, text: text)
            incoming.append(KnowledgeEntry(id: "\(manifest.id)-\(hash.prefix(16))", kind: item.kind, target: item.target,
                                           pack: manifest.id, text: text, meta: item.meta ?? [:]))
        }

        try await store.registerPack(KnowledgePackInfo(id: manifest.id, name: manifest.name, version: manifest.version,
                                                       license: manifest.license, attribution: manifest.attribution))
        let stale = try await store.packEntryIDs(pack: manifest.id).subtracting(incoming.map(\.id))
        if !stale.isEmpty { try await store.delete(ids: Array(stale)) }
        return try await store.addAll(incoming)
    }
}
