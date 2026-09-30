import Foundation
import os

public enum BriefStoreError: LocalizedError, Equatable {
    case notFound(String)
    case invalidID(String)
    public var errorDescription: String? {
        switch self {
        case .notFound: "That brief no longer exists."
        case .invalidID: "That brief can't be saved: its id isn't a plain name."
        }
    }
}

/// The user's briefs: one JSON file each, so they are easy to back up and diff. Same shape as
/// `PromptLibrary`. All writes go through here.
public actor BriefStore {
    public nonisolated let directory: URL
    private var briefs: [String: Brief] = [:]
    /// Every file each brief was read from or written to, so delete removes copies too.
    private var files: [String: Set<URL>] = [:]
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
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in entries where file.pathExtension == "json" {
            do {
                let brief = try Self.decoder.decode(Brief.self, from: Data(contentsOf: file))
                guard brief.schemaVersion <= Brief.currentVersion else {
                    logger.error("skipping newer brief \(file.lastPathComponent, privacy: .public)")
                    continue
                }
                files[brief.id, default: []].insert(file)
                if briefs[brief.id] == nil { briefs[brief.id] = brief }
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
        guard Self.isPlainName(brief.id) else { throw BriefStoreError.invalidID(brief.id) }
        // Names are compared case-insensitively because the volume usually is.
        if briefs.keys.contains(where: { $0 != brief.id && $0.lowercased() == brief.id.lowercased() }) {
            throw BriefStoreError.invalidID(brief.id)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = url(for: brief.id)
        try Self.encoder.encode(brief).write(to: target, options: .atomic)
        briefs[brief.id] = brief
        files[brief.id, default: []].insert(target)
    }

    public func delete(id: String) throws {
        load()
        guard briefs[id] != nil else { throw BriefStoreError.notFound(id) }
        for file in files[id] ?? [] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        briefs[id] = nil
        files[id] = nil
    }

    public func exportMarkdown(id: String, to url: URL) throws {
        load()
        guard let brief = briefs[id] else { throw BriefStoreError.notFound(id) }
        let compiled = BriefCompiler.compile(brief)
        var out = "# \(brief.title)\n\n"
        if !compiled.warnings.isEmpty {
            out += "Warnings:\n" + compiled.warnings.map { "- \($0.message)" }.joined(separator: "\n") + "\n\n"
        }
        out += "---\n\n" + compiled.text + "\n"
        try Data(out.utf8).write(to: url, options: .atomic)
    }

    /// Ids become file names, so only letters, digits, `-` and `_` are accepted (a UUID qualifies).
    static func isPlainName(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }
    }

    private func url(for id: String) -> URL { directory.appendingPathComponent(id + ".json") }
}
