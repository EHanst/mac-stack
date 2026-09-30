import Testing
import Foundation
@testable import StackCore

@Suite("BriefExporter")
struct BriefExporterTests {
    private func brief(title: String = "Fix login timeout", goal: String = "Add a retry") -> Brief {
        var b = Brief.new(title: title, target: .make(modelFamily: "claude", surface: .claudeCode))
        b.setText(goal, for: .goal)
        return b
    }
    private func tempRoot() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test("slug is a safe short file name", arguments: [
        ("Fix login timeout", "fix-login-timeout"),
        ("../../etc/passwd", "etc-passwd"),
        ("   ", "brief"),
        ("Ünïcode & symbols!!", "n-code-symbols"),
    ])
    func slug(title: String, expected: String) {
        #expect(BriefExporter.slug(title) == expected)
        #expect(BriefExporter.slug(String(repeating: "a", count: 200)).count <= 40)
    }

    @Test("markdown has front matter and the compiled prompt, never a secret")
    func markdown() throws {
        let text = try #require(BriefExporter.markdown(for: brief(goal: "Use AKIAIOSFODNN7EXAMPLE to upload")))
        #expect(text.hasPrefix("---\ntitle: \"Fix login timeout\"\n"))
        #expect(text.contains("Use "))
        #expect(!text.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    @Test("a title with quotes or newlines cannot break the front matter")
    func titleEscaping() throws {
        let text = try #require(BriefExporter.markdown(for: brief(title: "a\"b\nc: d")))
        let head = text.components(separatedBy: "---\n")[1]
        #expect(head.split(separator: "\n").count == 2)   // title and target only
    }

    @Test("no goal means nothing to export")
    func emptyGoal() {
        #expect(BriefExporter.markdown(for: brief(goal: " ")) == nil)
        #expect(throws: BriefExportError.emptyGoal) { try BriefExporter.export(brief(goal: ""), toProjectRoot: tempRoot()) }
    }

    @Test("export writes under .vibe/briefs and re-exporting the same brief overwrites one file")
    func writes() throws {
        let root = tempRoot()
        let b = brief()
        let url = try BriefExporter.export(b, toProjectRoot: root)
        #expect(url.deletingLastPathComponent().path.hasSuffix("/.vibe/briefs"))
        #expect(url.lastPathComponent.hasSuffix(".md"))
        var edited = b; edited.setText("Different goal", for: .goal)
        let again = try BriefExporter.export(edited, toProjectRoot: root)
        #expect(again == url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Different goal"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
    }

    @Test("a .vibe folder that points outside the project is refused")
    func symlinkEscape() throws {
        let root = tempRoot(), outside = tempRoot()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".vibe"), withDestinationURL: outside)
        #expect(throws: BriefExportError.outsideProject) { try BriefExporter.export(brief(), toProjectRoot: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("a secret in the title never reaches the file name")
    func titleSecretNotInFileName() {
        let name = BriefExporter.fileName(for: brief(title: "Deploy with AKIAIOSFODNN7EXAMPLE now"))
        #expect(!name.lowercased().contains("akiaiosfodnn7example"))
    }
}
