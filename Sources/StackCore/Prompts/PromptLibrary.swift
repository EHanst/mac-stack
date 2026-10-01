import Foundation
import os

/// The user's saved prompts: one small JSON file each in a folder, so they are easy to back up,
/// diff and export. All edits go through here; nothing else writes the folder.
public actor PromptLibrary {

    public enum LibraryError: LocalizedError, Equatable {
        case slashInUse(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .slashInUse(let s): "/\(s) already belongs to another prompt."
            case .notFound: "That prompt no longer exists."
            }
        }
    }

    public nonisolated let directory: URL
    private var prompts: [String: SavedPrompt] = [:]
    private var loaded = false
    private let logger = Logger(subsystem: "com.vibecockpit", category: "PromptLibrary")

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/Prompts", isDirectory: true)
    }

    public init(directory: URL = PromptLibrary.defaultDirectory()) {
        self.directory = directory
    }

    // MARK: Loading and seeding

    /// Reads the folder. Starter prompts are added once
    /// (a marker file records that), so deleting one doesn't bring it back.
    public func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decoder = Self.decoder
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            do {
                let prompt = try decoder.decode(SavedPrompt.self, from: Data(contentsOf: file))
                if prompt.id.hasPrefix("builtin.recipe.") {   // per-task guidance, retired
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                prompts[prompt.id] = prompt
            } catch {
                logger.error("skipping unreadable prompt \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let marker = directory.appendingPathComponent(".starters-v1")
        if !FileManager.default.fileExists(atPath: marker.path) {
            for starter in BuiltInPrompts.starters where prompts[starter.id] == nil { prompts[starter.id] = starter; write(starter) }
            try? Data().write(to: marker)
        }
    }

    // MARK: Reading

    public func all() -> [SavedPrompt] {
        load()
        return prompts.values.sorted(by: Self.order)
    }

    public func prompt(id: String) -> SavedPrompt? {
        load()
        return prompts[id]
    }

    /// Pinned first, then most recently used.
    public func userPrompts() -> [SavedPrompt] { all() }

    public func prompt(slash: String) -> SavedPrompt? {
        guard let key = SavedPrompt.cleanSlash(slash) else { return nil }
        return all().first { $0.slash == key }
    }

    /// Case-insensitive match on title, body, tags and slash name. Empty query = everything.
    public func search(_ query: String) -> [SavedPrompt] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return all().filter { p in
            let haystack = ([p.title, p.body, p.slash ?? ""] + p.tags).joined(separator: "\n").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: Writing

    /// Adds or updates a prompt. If the title or body changed, the old text is kept as a version.
    @discardableResult
    public func save(_ incoming: SavedPrompt, now: Date = Date()) throws -> SavedPrompt {
        load()
        var prompt = incoming
        if let slash = prompt.slash,
           prompts.values.contains(where: { $0.id != prompt.id && $0.slash == slash }) {
            throw LibraryError.slashInUse(slash)
        }
        if let old = prompts[prompt.id] {
            prompt.createdAt = old.createdAt
            prompt.versions = old.versions
            prompt.useCount = old.useCount
            prompt.lastUsed = old.lastUsed
            if old.title != prompt.title || old.body != prompt.body {
                prompt.versions.append(.init(date: old.updatedAt, title: old.title, body: old.body))
                if prompt.versions.count > SavedPrompt.maxVersions {
                    prompt.versions.removeFirst(prompt.versions.count - SavedPrompt.maxVersions)
                }
                prompt.updatedAt = now
            } else {
                prompt.updatedAt = old.updatedAt
            }
        }
        prompts[prompt.id] = prompt
        write(prompt)
        return prompt
    }

    public func delete(id: String) throws {
        load()
        guard let p = prompts[id] else { throw LibraryError.notFound(id) }
        prompts[id] = nil
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Puts an earlier version back (the current text becomes a version, so this can be undone too).
    @discardableResult
    public func restore(id: String, versionIndex: Int) throws -> SavedPrompt {
        load()
        guard var p = prompts[id], p.versions.indices.contains(versionIndex) else { throw LibraryError.notFound(id) }
        let v = p.versions[versionIndex]
        p.title = v.title
        p.body = v.body
        return try save(p)
    }

    /// Gives a starter its shipped text back.
    @discardableResult
    public func resetToDefault(id: String) throws -> SavedPrompt {
        load()
        guard var p = prompts[id], p.builtIn else { throw LibraryError.notFound(id) }
        let original = BuiltInPrompts.starters.first { $0.id == id }
        guard let original else { throw LibraryError.notFound(id) }
        p.title = original.title
        p.body = original.body
        return try save(p)
    }

    /// Records that a prompt was used (drives "recent" and the use count).
    public func markUsed(id: String, now: Date = Date()) {
        load()
        guard var p = prompts[id] else { return }
        p.useCount += 1
        p.lastUsed = now
        prompts[id] = p
        write(p)
    }

    // MARK: Import / export

    /// A prompt as Markdown with a small header, for sharing or committing to a repository.
    public static func exportMarkdown(_ p: SavedPrompt) -> String {
        var head = ["title: \(p.title.replacingOccurrences(of: "\n", with: " "))"]
        if let slash = p.slash { head.append("slash: \(slash)") }
        if !p.tags.isEmpty { head.append("tags: \(p.tags.joined(separator: ", "))") }
        return "---\n" + head.joined(separator: "\n") + "\n---\n" + p.body + "\n"
    }

    /// Reads what `exportMarkdown` wrote (or any Markdown file: the file name becomes the title).
    public static func importMarkdown(_ text: String, fallbackTitle: String) -> SavedPrompt {
        var title = fallbackTitle, slash: String?, tags: [String] = [], body = text
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let header = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in header.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "title": if !value.isEmpty { title = value }
                case "slash": slash = value
                case "tags": tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                default: break
                }
            }
            body = String(text[end.upperBound...])
        }
        return SavedPrompt(title: title, body: body.trimmingCharacters(in: .whitespacesAndNewlines), tags: tags, slash: slash)
    }

    // MARK: Files

    private static func order(_ a: SavedPrompt, _ b: SavedPrompt) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        switch (a.lastUsed, b.lastUsed) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        return (a.title.lowercased(), a.id) < (b.title.lowercased(), b.id)
    }

    private func file(for id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    private func write(_ prompt: SavedPrompt) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(prompt).write(to: file(for: prompt.id), options: .atomic)
        } catch {
            logger.error("couldn't save prompt: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
