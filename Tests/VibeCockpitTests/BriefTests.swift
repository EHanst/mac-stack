import Testing
import Foundation
@testable import StackCore

@Suite("Brief")
struct BriefTests {
    private func target() -> TargetProfile { .make(modelFamily: "claude", surface: .claudeCode) }

    @Test("v1 migration joins enabled non-empty sections in order and leaves body nil")
    func v1Migration() throws {
        let json = """
        {
          "id": "abc",
          "schemaVersion": 1,
          "title": "Old",
          "workspace": null,
          "target": {"modelFamily":"claude","surface":"claudeCode","tokenBudget":20000},
          "sections": [
            {"kind":"goal","text":"Fix login","enabled":true},
            {"kind":"context","text":"Some context","enabled":true},
            {"kind":"constraints","text":"","enabled":true},
            {"kind":"examples","text":"Example","enabled":false},
            {"kind":"outputFormat","text":"JSON","enabled":true}
          ],
          "contextItems": [],
          "versions": [],
          "createdAt": "2026-09-30T00:00:00Z",
          "updatedAt": "2026-09-30T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let brief = try decoder.decode(Brief.self, from: json)

        #expect(brief.schemaVersion == Brief.currentVersion)
        #expect(brief.input == "## Goal\nFix login\n\n## Context\nSome context\n\n## Output format\nJSON")
        #expect(brief.body == nil)
        #expect(brief.effectiveBody == brief.input)
        #expect(brief.isEdited == false)
    }

    private func v1Brief(contextEnabled: Bool) throws -> Brief {
        let items = try JSONEncoder().encode([ContextItem(id: "i", kind: .file, ref: "A.swift", text: "let a = 1",
                                                          mode: .inline, included: true)])
        let json = """
        {
          "id": "abc", "schemaVersion": 1, "title": "Old", "workspace": null,
          "target": {"modelFamily":"claude","surface":"claudeCode","tokenBudget":20000},
          "sections": [
            {"kind":"goal","text":"Fix login","enabled":true},
            {"kind":"context","text":"Some context","enabled":\(contextEnabled)}
          ],
          "contextItems": \(String(decoding: items, as: UTF8.self)),
          "versions": [],
          "createdAt": "2026-09-30T00:00:00Z", "updatedAt": "2026-09-30T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Brief.self, from: json)
    }

    @Test("v1 migration with the context section switched off excludes the context items")
    func v1MigrationContextDisabled() throws {
        let brief = try v1Brief(contextEnabled: false)
        #expect(brief.contextItems.count == 1)
        #expect(brief.contextItems[0].included == false)
    }

    @Test("v1 migration with the context section on keeps the context items as they were")
    func v1MigrationContextEnabled() throws {
        let brief = try v1Brief(contextEnabled: true)
        #expect(brief.contextItems[0].included == true)
    }

    @Test("v2 round-trips input and body, both nil and non-nil")
    func v2Codable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var linked = Brief.new(title: "t", input: "Do X", target: .make(modelFamily: "claude", surface: .claudeCode),
                               now: Date(timeIntervalSince1970: 1_800_000_000))   // whole seconds: .iso8601 drops fractions
        linked.contextItems = [ContextItem(kind: .file, ref: "a.swift", text: "let a = 1", mode: .inline)]
        let linkedBack = try decoder.decode(Brief.self, from: encoder.encode(linked))
        #expect(linkedBack == linked)
        #expect(linkedBack.body == nil)

        var edited = linked
        edited.body = "Edited body"
        let editedBack = try decoder.decode(Brief.self, from: encoder.encode(edited))
        #expect(editedBack == edited)
        #expect(editedBack.body == "Edited body")
    }

    @Test("snapshot keeps the earlier text and caps history at maxVersions")
    func versions() {
        var b = Brief.new(title: "t", target: target())
        for i in 0..<(Brief.maxVersions + 5) {
            b.input = "v\(i)"
            b.snapshot()
        }
        #expect(b.versions.count == Brief.maxVersions)
        #expect(b.versions.last?.input == "v\(Brief.maxVersions + 4)")
    }
}
