import Testing
import Foundation
@testable import StackCore

@Suite("Brief")
struct BriefTests {
    private func target() -> TargetProfile { .make(modelFamily: "claude", surface: .claudeCode) }

    @Test("a new brief has all five sections, all enabled and empty")
    func newBrief() {
        let b = Brief.new(title: "Fix login", target: target())
        #expect(b.sections.map(\.kind) == BriefSection.Kind.allCases)
        #expect(b.sections.allSatisfy { $0.enabled && $0.text.isEmpty })
        #expect(b.schemaVersion == Brief.currentVersion)
    }

    @Test("setText edits one section and leaves the others alone")
    func setText() {
        var b = Brief.new(title: "t", target: target())
        b.setText("Fix the crash", for: .goal)
        #expect(b.text(of: .goal) == "Fix the crash")
        #expect(b.text(of: .constraints).isEmpty)
    }

    @Test("snapshot keeps the earlier sections and caps history at maxVersions")
    func versions() {
        var b = Brief.new(title: "t", target: target())
        for i in 0..<(Brief.maxVersions + 5) {
            b.setText("v\(i)", for: .goal)
            b.snapshot()
        }
        #expect(b.versions.count == Brief.maxVersions)
        #expect(b.versions.last?.sections.first { $0.kind == .goal }?.text == "v\(Brief.maxVersions + 4)")
    }

    @Test("round-trips through JSON, context items included")
    func codable() throws {
        var b = Brief.new(title: "t", target: target())
        b.contextItems = [ContextItem(kind: .file, ref: "Sources/A.swift", text: "let a = 1", mode: .inline,
                                      tokens: 4, provenance: "search: login")]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Brief.self, from: enc.encode(b))
        #expect(back.contextItems == b.contextItems && back.title == b.title)
    }
}
