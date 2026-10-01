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
        Brief.new(title: title, input: "Do the thing", target: .make(modelFamily: "claude", surface: .claudeCode))
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

    @Test("export is a Markdown file: a title, any warnings, then the compiled prompt")
    func export() async throws {
        let s = store()
        var b = brief("Exp")
        b.target.tokenBudget = 20
        b.contextItems = [ContextItem(id: "big", kind: .file, ref: "Big.swift", text: String(repeating: "x", count: 500), mode: .inline)]
        try await s.save(b)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).md")
        try await s.exportMarkdown(id: b.id, to: out)
        let text = try String(contentsOf: out, encoding: .utf8)
        let compiled = BriefCompiler.compile(b)
        #expect(text.hasPrefix("# Exp\n"))
        #expect(text.contains(compiled.text))
        #expect(compiled.warnings.allSatisfy { text.contains($0.message) } && !compiled.warnings.isEmpty)
    }

    private func writeV1BackupFixture(to directory: URL, id: String = "backupme") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {"id":"\(id)","schemaVersion":1,"title":"Old","workspace":null,\
        "target":{"modelFamily":"claude","surface":"claudeCode","tokenBudget":20000},\
        "sections":[{"kind":"goal","text":"Do thing","enabled":true}],\
        "contextItems":[],"versions":[],"createdAt":"2026-09-30T00:00:00Z","updatedAt":"2026-09-30T00:00:00Z"}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(id).json"))
    }

    @Test("the first v2 save copies the original v1 file to <id>.v1.json byte for byte")
    func v1BackupCreated() async throws {
        let s = store()
        try writeV1BackupFixture(to: s.directory)
        let original = try Data(contentsOf: s.directory.appendingPathComponent("backupme.json"))

        let first = BriefStore(directory: s.directory)
        let migrated = try #require(await first.brief(id: "backupme"))
        #expect(migrated.schemaVersion == Brief.currentVersion)
        #expect(migrated.body == nil)
        let backup = s.directory.appendingPathComponent("backupme.v1.json")
        #expect(!FileManager.default.fileExists(atPath: backup.path))   // loading alone writes nothing

        try await first.save(migrated)
        #expect(try Data(contentsOf: backup) == original)
        // The live file is now v2; a fresh store sees one brief, not the backup as a second one.
        #expect(await BriefStore(directory: s.directory).all().count == 1)
    }

    @Test("an existing backup is never overwritten")
    func v1BackupNotOverwritten() async throws {
        let s = store()
        try writeV1BackupFixture(to: s.directory)
        let backup = s.directory.appendingPathComponent("backupme.v1.json")
        try Data("already here".utf8).write(to: backup)

        let first = BriefStore(directory: s.directory)
        let migrated = try #require(await first.brief(id: "backupme"))
        try await first.save(migrated)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "already here")
    }

    @Test("deleting a migrated brief removes its backup too")
    func v1BackupDeleted() async throws {
        let s = store()
        try writeV1BackupFixture(to: s.directory)
        let first = BriefStore(directory: s.directory)
        let migrated = try #require(await first.brief(id: "backupme"))
        try await first.save(migrated)

        let fresh = BriefStore(directory: s.directory)
        try await fresh.delete(id: "backupme")
        #expect(!FileManager.default.fileExists(atPath: s.directory.appendingPathComponent("backupme.v1.json").path))
        #expect(await BriefStore(directory: s.directory).all().isEmpty)
    }

    @Test("a file from a newer schema is skipped, not migrated")
    func futureSchemaSkipped() async throws {
        let s = store()
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        let json = """
        {"id":"future","schemaVersion":3,"title":"New","target":{"modelFamily":"claude","surface":"claudeCode","tokenBudget":20000},\
        "input":"x","contextItems":[],"versions":[],"createdAt":"2026-09-30T00:00:00Z","updatedAt":"2026-09-30T00:00:00Z"}
        """
        try Data(json.utf8).write(to: s.directory.appendingPathComponent("future.json"))
        #expect(await BriefStore(directory: s.directory).all().isEmpty)
    }
}
