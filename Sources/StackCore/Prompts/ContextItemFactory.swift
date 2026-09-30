import Foundation
import CryptoKit

public enum ContextItemError: LocalizedError, Equatable {
    case outsideWorkspace, unreadable, binary, tooLarge(Int), noChanges, noWorkspace

    public var errorDescription: String? {
        switch self {
        case .outsideWorkspace: "That file is outside your project folders."
        case .unreadable: "That file could not be read."
        case .binary: "That file is not text, so it cannot go in a prompt."
        case .tooLarge(let bytes): "That file is too large (\(bytes / 1000) KB). Pick a smaller one or a symbol."
        case .noChanges: "There are no uncommitted changes to add."
        case .noWorkspace: "Add a project in Settings first."
        }
    }
}

/// Turns files, search hits and diffs into `ContextItem`s. Ids are derived from content, so adding
/// the same thing twice updates one item instead of stacking duplicates.
public enum ContextItemFactory {
    public static let maxFileBytes = 200_000
    /// Working changes are the most specific context, so they are dropped last when over budget.
    static let diffPriority = 100

    public static func file(at url: URL, roots: [URL], surface: Surface, provenance: String) throws -> ContextItem {
        let resolved = url.resolvingSymlinksInPath()
        guard let root = roots.map({ $0.resolvingSymlinksInPath() }).first(where: { contains($0, resolved) }) else {
            throw ContextItemError.outsideWorkspace
        }
        // Look before reading: a directory, a pipe or a multi-gigabyte log must not be loaded to find out.
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { throw ContextItemError.unreadable }
        if let size = values.fileSize, size > maxFileBytes { throw ContextItemError.tooLarge(size) }
        guard let data = try? Data(contentsOf: resolved) else { throw ContextItemError.unreadable }
        guard data.count <= maxFileBytes else { throw ContextItemError.tooLarge(data.count) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw ContextItemError.binary }
        return ContextItem(id: id("file:" + resolved.path), kind: .file, ref: relative(resolved, to: root), text: text,
                           mode: surface.defaultContextMode, provenance: provenance)
    }

    public static func hit(filePath: String, kind: String, content: String, query: String,
                           roots: [URL], surface: Surface) -> ContextItem {
        let url = URL(fileURLWithPath: filePath)
        let root = roots.first { contains($0, url) }
        let path = root.map { relative(url, to: $0) } ?? url.lastPathComponent
        return ContextItem(id: id("hit:" + filePath + "\n" + content), kind: .symbol, ref: "\(path) — \(kind)",
                           text: content, mode: surface.defaultContextMode, provenance: "search: \(query)")
    }

    public static func diff(_ text: String, ref: String) -> ContextItem {
        ContextItem(id: id("diff:" + ref), kind: .gitDiff, ref: ref, text: text, mode: .inline,
                    provenance: "uncommitted changes", priority: diffPriority)
    }

    private static func contains(_ root: URL, _ file: URL) -> Bool {
        file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    private static func relative(_ file: URL, to root: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func id(_ seed: String) -> String {
        SHA256.hash(data: Data(seed.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
