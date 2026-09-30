import Testing
import Foundation
@testable import StackCore

@Suite("BriefStore")
struct BriefStoreTests {
    private func store() -> BriefStore {
        BriefStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("briefs-\(UUID().uuidString)", isDirectory: true))
    }
    private func brief(_ title: String) -> Brief {
        var b = Brief.new(title: title, target: .make(modelFamily: "claude", surface: .claudeCode))
        b.setText("Do the thing", for: .goal)
        return b
    }

    @Test("a saved brief survives a relaunch")
    func persists() async throws {
        let s = store()
        let b = brief("One")
        try await s.save(b)
        let again = BriefStore(directory: s.directory)
        #expect(await again.brief(id: b.id)?.title == "One")
    }

    @Test("all() lists the most recently updated first")
    func ordering() async throws {
        let s = store()
        var older = brief("Old"); older.updatedAt = Date(timeIntervalSince1970: 100)
        var newer = brief("New"); newer.updatedAt = Date(timeIntervalSince1970: 200)
        try await s.save(older); try await s.save(newer)
        #expect(await s.all().map(\.title) == ["New", "Old"])
    }

    @Test("delete removes the file, and deleting a missing brief throws notFound")
    func delete() async throws {
        let s = store()
        let b = brief("Gone")
        try await s.save(b)
        try await s.delete(id: b.id)
        #expect(await s.brief(id: b.id) == nil)
        await #expect(throws: BriefStoreError.self) { try await s.delete(id: b.id) }
    }

    @Test("a corrupt or future-version file is skipped and the rest still load")
    func corrupt() async throws {
        let s = store()
        try await s.save(brief("Good"))
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: s.directory.appendingPathComponent("bad.json"))
        var future = brief("Future"); future.schemaVersion = Brief.currentVersion + 1
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(future).write(to: s.directory.appendingPathComponent("\(future.id).json"))
        let fresh = BriefStore(directory: s.directory)
        #expect(await fresh.all().map(\.title) == ["Good"])
    }

    @Test("an id that isn't a plain name is refused, so nothing is written outside the folder")
    func pathSafety() async throws {
        let s = store()
        for bad in ["../../escape", "a/b", "", "a.b"] {
            var b = brief("Evil"); b.id = bad
            await #expect(throws: BriefStoreError.self) { try await s.save(b) }
        }
        let escaped = s.directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("escape.json")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        #expect(await s.all().isEmpty)
    }

    @Test("two ids that differ only by case cannot overwrite each other's file")
    func caseCollision() async throws {
        let s = store()
        var a = brief("A"); a.id = "abc"
        var b = brief("B"); b.id = "ABC"
        try await s.save(a)
        await #expect(throws: BriefStoreError.self) { try await s.save(b) }
        #expect(await s.brief(id: "abc")?.title == "A")
    }

    @Test("a copied file with the same id is ignored, and delete removes the brief for good")
    func copiedFile() async throws {
        let s = store()
        let b = brief("Orig")
        try await s.save(b)
        let copy = s.directory.appendingPathComponent("\(b.id) copy.json")
        try FileManager.default.copyItem(at: s.directory.appendingPathComponent("\(b.id).json"), to: copy)
        let fresh = BriefStore(directory: s.directory)
        #expect(await fresh.all().count == 1)
        try await fresh.delete(id: b.id)
        #expect(await BriefStore(directory: s.directory).all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test("markdown export is the compiled prompt")
    func export() async throws {
        let s = store()
        let b = brief("Exp")
        try await s.save(b)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).md")
        try await s.exportMarkdown(id: b.id, to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == BriefCompiler.compile(b).text)
    }
}
