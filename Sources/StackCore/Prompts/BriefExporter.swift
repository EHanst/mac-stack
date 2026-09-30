import Foundation

public enum BriefExportError: LocalizedError, Equatable {
    case emptyGoal
    case outsideProject
    public var errorDescription: String? {
        switch self {
        case .emptyGoal: "Write a goal first, then save."
        case .outsideProject: "The project's .vibe folder points outside the project, so nothing was written."
        }
    }
}

/// Writes a brief into a project as `.vibe/briefs/<name>.md`, for tools that read files in the repo.
public enum BriefExporter {

    public static func slug(_ title: String) -> String {
        var out = ""
        var lastDash = true
        for ch in title.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        out = String(out.prefix(40))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "brief" : out
    }

    /// Stable per brief, so saving again replaces the file instead of adding another.
    public static func fileName(for brief: Brief) -> String {
        "\(slug(brief.title))-\(slug(String(brief.id.prefix(8)))).md"
    }

    /// nil when the brief has no goal.
    public static func markdown(for brief: Brief) -> String? {
        let compiled = BriefCompiler.compile(brief)
        if compiled.warnings.contains(where: { $0.code == .emptyGoal }) { return nil }
        let title = ContextRedactor.redact(brief.title).text
            .components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let head = "---\ntitle: \"\(title)\"\ntarget: \(brief.target.surface.displayName)\n---\n\n"
        return head + compiled.text + "\n"
    }

    @discardableResult
    public static func export(_ brief: Brief, toProjectRoot root: URL) throws -> URL {
        guard let text = markdown(for: brief) else { throw BriefExportError.emptyGoal }
        let fm = FileManager.default
        let dir = root.appendingPathComponent(".vibe/briefs", isDirectory: true)
        let realRoot = root.resolvingSymlinksInPath().path
        // Check before creating anything: a symlinked .vibe must not make us write outside the project.
        let vibe = root.appendingPathComponent(".vibe", isDirectory: true)
        if fm.fileExists(atPath: vibe.path), vibe.resolvingSymlinksInPath().path != realRoot + "/.vibe" {
            throw BriefExportError.outsideProject
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let realDir = dir.resolvingSymlinksInPath().path
        guard realDir == realRoot + "/.vibe/briefs" else { throw BriefExportError.outsideProject }
        let file = dir.appendingPathComponent(fileName(for: brief))
        try Data(text.utf8).write(to: file, options: .atomic)
        return file
    }
}
