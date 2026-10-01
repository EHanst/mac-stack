import Testing
import Foundation
@testable import StackCore

@Suite("PromptLibrary")
struct PromptLibraryTests {

    private func makeLibrary() -> PromptLibrary {
        PromptLibrary(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("prompts-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("first load seeds the starter pack")
    func seeds() async {
        let lib = makeLibrary()
        #expect(await lib.userPrompts().count == BuiltInPrompts.starters.count)
        #expect(await lib.prompt(slash: "/review")?.title == "Review a file")
    }

    @Test("a deleted starter does not come back on the next launch")
    func startersOnce() async throws {
        let lib = makeLibrary()
        try await lib.delete(id: "builtin.starter.review")
        let again = PromptLibrary(directory: lib.directory)
        #expect(await again.prompt(id: "builtin.starter.review") == nil)
        #expect(await again.all().count == BuiltInPrompts.starters.count - 1)
    }

    @Test("saved prompts survive a relaunch")
    func persists() async throws {
        let lib = makeLibrary()
        let saved = try await lib.save(SavedPrompt(title: "Mine", body: "Do {{x}}", tags: ["a"], slash: "Mine"))
        let again = PromptLibrary(directory: lib.directory)
        let loaded = await again.prompt(id: saved.id)
        #expect(loaded?.body == "Do {{x}}")
        #expect(loaded?.slash == "mine")
    }

    @Test("editing keeps the old text as a version; restoring is itself undoable")
    func versions() async throws {
        let lib = makeLibrary()
        var p = try await lib.save(SavedPrompt(title: "T", body: "one"))
        p.body = "two"
        p = try await lib.save(p)
        #expect(p.versions.map(\.body) == ["one"])
        let restored = try await lib.restore(id: p.id, versionIndex: 0)
        #expect(restored.body == "one")
        #expect(restored.versions.map(\.body) == ["one", "two"])
    }

    @Test("saving without changing the text adds no version")
    func noNoiseVersions() async throws {
        let lib = makeLibrary()
        var p = try await lib.save(SavedPrompt(title: "T", body: "one"))
        p.pinned = true
        p = try await lib.save(p)
        #expect(p.versions.isEmpty)
    }

    @Test("history is capped")
    func versionCap() async throws {
        let lib = makeLibrary()
        var p = try await lib.save(SavedPrompt(title: "T", body: "0"))
        for i in 1...(SavedPrompt.maxVersions + 5) { p.body = "\(i)"; p = try await lib.save(p) }
        #expect(p.versions.count == SavedPrompt.maxVersions)
    }

    @Test("two prompts can't share a slash name")
    func slashUnique() async throws {
        let lib = makeLibrary()
        _ = try await lib.save(SavedPrompt(title: "A", body: "a", slash: "go"))
        await #expect(throws: PromptLibrary.LibraryError.slashInUse("go")) {
            try await lib.save(SavedPrompt(title: "B", body: "b", slash: "/GO"))
        }
    }

    @Test("a built-in starter can be reset to its shipped text")
    func starterReset() async throws {
        let lib = makeLibrary()
        let id = "builtin.starter.review"
        var starter = try #require(await lib.prompt(id: id))
        let shipped = starter.body
        starter.body = "Custom"
        _ = try await lib.save(starter)
        _ = try await lib.resetToDefault(id: id)
        #expect(await lib.prompt(id: id)?.body == shipped)
    }

    @Test("retired per-task guidance files are removed on load")
    func retiredRecipes() async throws {
        let lib = makeLibrary()
        _ = await lib.all()
        let file = lib.directory.appendingPathComponent("builtin.recipe.debug.json")
        let old = SavedPrompt(id: "builtin.recipe.debug", title: "Guidance", body: "x", builtIn: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(old).write(to: file)
        let again = PromptLibrary(directory: lib.directory)
        #expect(await again.prompt(id: old.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("search matches title, body and tags; pinned and recently used come first")
    func searchAndOrder() async throws {
        let lib = makeLibrary()
        let a = try await lib.save(SavedPrompt(title: "Alpha", body: "network retry", tags: ["net"]))
        let b = try await lib.save(SavedPrompt(title: "Beta", body: "network cache"))
        await lib.markUsed(id: b.id)
        #expect(await lib.search("network").map(\.id) == [b.id, a.id])
        #expect(await lib.search("net retry").map(\.id) == [a.id])
        var pinned = a
        pinned.pinned = true
        _ = try await lib.save(pinned)
        #expect(await lib.search("network").first?.id == a.id)
    }

    @Test("markdown export and import round-trip")
    func markdown() {
        let p = SavedPrompt(title: "Ship it", body: "Do {{x}}\nthen stop", tags: ["a", "b"], slash: "ship")
        let back = PromptLibrary.importMarkdown(PromptLibrary.exportMarkdown(p), fallbackTitle: "x")
        #expect(back.title == "Ship it")
        #expect(back.slash == "ship")
        #expect(back.tags == ["a", "b"])
        #expect(back.body == "Do {{x}}\nthen stop")
        #expect(PromptLibrary.importMarkdown("just text", fallbackTitle: "note.md").title == "note.md")
    }

    @Test("a corrupt file is skipped, not fatal")
    func corrupt() async throws {
        let lib = makeLibrary()
        _ = await lib.all()
        try Data("{ nope".utf8).write(to: lib.directory.appendingPathComponent("bad.json"))
        let again = PromptLibrary(directory: lib.directory)
        #expect(await again.all().count == BuiltInPrompts.starters.count)
    }
}
