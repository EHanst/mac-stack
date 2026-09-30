import Testing
import Foundation
@testable import StackCore

@Suite("ContextItemFactory")
struct ContextItemFactoryTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    @Test("a file becomes an item with a relative ref and the surface's default mode")
    func file() throws {
        let root = try makeRoot()
        try "func a() {}".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let item = try ContextItemFactory.file(at: root.appendingPathComponent("a.swift"), roots: [root],
                                               surface: .claudeCode, provenance: "picked")
        #expect(item.ref == "a.swift")
        #expect(item.mode == .reference)
        #expect(item.tokens > 0 && item.text == "func a() {}")
        let again = try ContextItemFactory.file(at: root.appendingPathComponent("a.swift"), roots: [root],
                                                surface: .chatGPTWeb, provenance: "picked")
        #expect(again.id == item.id && again.mode == .inline)
    }

    @Test("paths outside every root are rejected, including through a symlink")
    func outside() throws {
        let root = try makeRoot()
        let other = try makeRoot()
        try "x".write(to: other.appendingPathComponent("o.txt"), atomically: true, encoding: .utf8)
        #expect(throws: ContextItemError.outsideWorkspace) {
            try ContextItemFactory.file(at: other.appendingPathComponent("o.txt"), roots: [root], surface: .other, provenance: "")
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"),
                                                   withDestinationURL: other.appendingPathComponent("o.txt"))
        #expect(throws: ContextItemError.outsideWorkspace) {
            try ContextItemFactory.file(at: root.appendingPathComponent("link.txt"), roots: [root], surface: .other, provenance: "")
        }
    }

    @Test("a sibling folder that shares the root's name prefix is outside")
    func prefixSibling() throws {
        let parent = try makeRoot()
        let root = parent.appendingPathComponent("app")
        let sibling = parent.appendingPathComponent("app-secrets")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "x".write(to: sibling.appendingPathComponent("k.txt"), atomically: true, encoding: .utf8)
        #expect(throws: ContextItemError.outsideWorkspace) {
            try ContextItemFactory.file(at: sibling.appendingPathComponent("k.txt"), roots: [root], surface: .other, provenance: "")
        }
    }

    @Test("binary, oversized and missing files are rejected with a reason")
    func rejects() throws {
        let root = try makeRoot()
        try Data([0, 1, 2, 0, 255]).write(to: root.appendingPathComponent("b.bin"))
        try String(repeating: "a", count: ContextItemFactory.maxFileBytes + 1)
            .write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        #expect(throws: ContextItemError.binary) {
            try ContextItemFactory.file(at: root.appendingPathComponent("b.bin"), roots: [root], surface: .other, provenance: "")
        }
        #expect(throws: ContextItemError.tooLarge(ContextItemFactory.maxFileBytes + 1)) {
            try ContextItemFactory.file(at: root.appendingPathComponent("big.txt"), roots: [root], surface: .other, provenance: "")
        }
        #expect(throws: ContextItemError.unreadable) {
            try ContextItemFactory.file(at: root.appendingPathComponent("missing.txt"), roots: [root], surface: .other, provenance: "")
        }
    }

    @Test("the same search hit gets the same id, and carries its query as provenance")
    func hit() {
        let root = URL(fileURLWithPath: "/w")
        let a = ContextItemFactory.hit(filePath: "/w/S.swift", kind: "func", content: "func f() {}", query: "login", roots: [root], surface: .cursor)
        let b = ContextItemFactory.hit(filePath: "/w/S.swift", kind: "func", content: "func f() {}", query: "login", roots: [root], surface: .cursor)
        #expect(a.id == b.id && a.kind == .symbol)
        #expect(a.provenance == "search: login")
        #expect(a.ref.hasPrefix("S.swift"))
    }

    @Test("a diff is inline and outranks files")
    func diff() {
        let d = ContextItemFactory.diff("+new line", ref: "working changes")
        #expect(d.kind == .gitDiff && d.mode == .inline && d.priority > 0)
    }
}
