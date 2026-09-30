import Foundation
import os

public enum BriefStoreError: LocalizedError, Equatable {
    case notFound(String)
    public var errorDescription: String? { "That brief no longer exists." }
}

/// The user's briefs: one JSON file each, so they are easy to back up and diff. Same shape as
/// `PromptLibrary`. All writes go through here.
public actor BriefStore {
    public nonisolated let directory: URL
    private var briefs: [String: Brief] = [:]
    private var loaded = false
    private let logger = Logger(subsystem: "com.vibecockpit", category: "BriefStore")

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/Briefs", isDirectory: true)
    }

    public init(directory: URL = BriefStore.defaultDirectory()) { self.directory = directory }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            do {
                let brief = try Self.decoder.decode(Brief.self, from: Data(contentsOf: file))
                guard brief.schemaVersion <= Brief.currentVersion else {
                    logger.error("skipping newer brief \(file.lastPathComponent, privacy: .public)")
                    continue
                }
                briefs[brief.id] = brief
            } catch {
                logger.error("skipping unreadable brief \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func all() -> [Brief] {
        load()
        return briefs.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func brief(id: String) -> Brief? { load(); return briefs[id] }

    public func save(_ brief: Brief) throws {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(brief).write(to: url(for: brief.id), options: .atomic)
        briefs[brief.id] = brief
    }

    public func delete(id: String) throws {
        load()
        guard briefs[id] != nil else { throw BriefStoreError.notFound(id) }
        try? FileManager.default.removeItem(at: url(for: id))
        briefs[id] = nil
    }

    public func exportMarkdown(id: String, to url: URL) throws {
        load()
        guard let brief = briefs[id] else { throw BriefStoreError.notFound(id) }
        try Data(BriefCompiler.compile(brief).text.utf8).write(to: url, options: .atomic)
    }

    /// The id becomes a file name, so anything that isn't a plain name is flattened: an id can never
    /// point outside the folder.
    private func url(for id: String) -> URL {
        let safe = String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        return directory.appendingPathComponent(safe + ".json")
    }
}
