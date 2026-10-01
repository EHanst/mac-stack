import Testing
import Foundation
import MCP
@testable import StackCore
@testable import StackMCP

private final class MemWorkspaces: WorkspaceStore, @unchecked Sendable {
    private let l = NSLock(); private var d: [WorkspaceRecord] = []
    func load() throws -> [WorkspaceRecord] { l.withLock { d } }
    func save(_ r: [WorkspaceRecord]) throws { l.withLock { d = r } }
}

/// Stands in for one project's `read_file`/`write_file`; reports which project ran it.
private struct FakeTool: AgentToolHandler {
    let name: String; let project: String; let scope: ClientScope
    var requiredScope: ClientScope { scope }
    var toolDefinition: Tool {
        Tool(name: name, description: "d", inputSchema: .object(["path": .object(["type": "string"])]))   // bare map, like the real ones
    }
    func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        let hasWorkspaceArg = arguments["workspace"] != nil
        return [.text("\(project):\(name):\(hasWorkspaceArg ? "leaked" : "clean")")]
    }
    func approvalSummary(arguments: [String: Value]) -> String { "Do \(name)" }
}

private func manager(_ store: MemWorkspaces = MemWorkspaces(), failing: Set<String> = []) -> WorkspaceManager {
    WorkspaceManager(store: store) { record in
        if failing.contains(record.name) { throw WorkspaceError.notAFolder(record.path) }
        return [FakeTool(name: "read_file", project: record.name, scope: .toolsRead),
                FakeTool(name: "write_file", project: record.name, scope: .toolsWrite)]
    }
}

private func folder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)/\(name)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func text(_ c: [Tool.Content]) -> String { if case .text(let t, _, _)? = c.first { t } else { "" } }

@Suite("Multiple projects")
struct WorkspaceManagerTests {

    @Test("with one project the workspace argument is optional; the tool still runs that project's copy")
    func single() async throws {
        let m = manager()
        try await m.add(folder("alpha"))
        let read = try #require(await m.tools().first { $0.toolDefinition.name == "read_file" })
        #expect(text(try await read.execute(arguments: [:])) == "alpha:read_file:clean")
        guard case .object(let schema) = read.toolDefinition.inputSchema, case .object(let props)? = schema["properties"] else {
            Issue.record("schema not valid JSON Schema"); return
        }
        #expect(props["workspace"] != nil && props["path"] != nil)
        #expect(schema["required"] == nil)
    }

    @Test("with several projects the argument is optional in the schema (the client's own folder is the default), routes correctly, and never reaches the tool")
    func several() async throws {
        let m = manager()
        try await m.add(folder("alpha")); try await m.add(folder("beta"))
        let write = try #require(await m.tools().first { $0.toolDefinition.name == "write_file" })
        #expect(write.requiredScope == .toolsWrite)
        if case .object(let s) = write.toolDefinition.inputSchema { #expect(s["required"] == nil) }

        #expect(text(try await write.execute(arguments: ["workspace": "beta"])) == "beta:write_file:clean")
        #expect(text(try await write.execute(arguments: ["workspace": "ALPHA"])) == "alpha:write_file:clean")   // by name, any case
        await #expect(throws: WorkspaceError.self) { try await write.execute(arguments: [:]) }
        await #expect(throws: WorkspaceError.self) { try await write.execute(arguments: ["workspace": "gamma"]) }
        // The approval prompt names the project the write would land in.
        #expect(write.approvalSummary(arguments: ["workspace": "beta"]) == "[beta] Do write_file")
    }

    @Test("a client's own folder picks the project: exact, inside it, longest wins, otherwise unmatched")
    func rootMatching() async throws {
        let m = manager()
        let outer = try folder("outer")
        let inner = outer.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let other = try folder("other")
        try await m.add(outer); try await m.add(inner); try await m.add(other)
        let read = try #require(await m.tools().first { $0.toolDefinition.name == "read_file" } as? WorkspaceRoutedTool)
        func id(_ name: String) -> RootMatch { .matched(name) }

        #expect(read.match(rootPaths: [other.path]) == id("other"))
        // Working in a sub-folder of a project uses that project; the most specific project wins.
        #expect(read.match(rootPaths: [outer.appendingPathComponent("Sources").path]) == id("outer"))
        #expect(read.match(rootPaths: [inner.path]) == id("inner"))
        // A folder that only shares a name prefix is not inside the project.
        #expect(read.match(rootPaths: [other.path + "-x"]) == .unmatched([other.path + "-x"]))
        #expect(read.match(rootPaths: ["/nowhere/at/all"]) == .unmatched(["/nowhere/at/all"]))
        // No roots offered: nothing to decide (old behaviour applies).
        #expect(read.match(rootPaths: []) == nil)
    }

    @Test("the whole disk and the whole home folder can't be opened as a project")
    func tooBroad() async throws {
        let m = manager()
        await #expect(throws: WorkspaceError.self) { try await m.add(URL(fileURLWithPath: "/")) }
        await #expect(throws: WorkspaceError.self) { try await m.add(FileManager.default.homeDirectoryForCurrentUser) }
        #expect(await m.list.isEmpty)
    }

    @Test("same folder name twice gets distinct ids; adding the same path twice is one project")
    func naming() async throws {
        let m = manager()
        let a = try await m.add(folder("app")), b = try await m.add(folder("app"))
        #expect(a.id != b.id)
        #expect(try await m.add(a.url).id == a.id)
        #expect(await m.list.count == 2)
    }

    @Test("a folder that can't open fails alone; removing a project removes its tools")
    func failureAndRemove() async throws {
        let m = manager(failing: ["broken"])
        let ok = try await m.add(folder("fine")); let bad = try await m.add(folder("broken"))
        let status = Dictionary(uniqueKeysWithValues: await m.list.map { ($0.record.id, $0.status) })
        #expect(status[ok.id] == .ready)
        if case .failed? = status[bad.id] {} else { Issue.record("broken should fail") }
        let names = await m.tools().map { $0.toolDefinition.name }
        #expect(names.contains("list_workspaces") && names.contains("read_file"))
        await m.remove(ok.id)
        #expect(await m.tools().isEmpty)
    }

    @Test("projects persist across launches; a file isn't a project")
    func persistence() async throws {
        let store = MemWorkspaces()
        let m1 = manager(store); try await m1.add(folder("keep"))
        let m2 = manager(store); await m2.openAll()
        #expect(await m2.list.map(\.record.name) == ["keep"])
        #expect(await m2.tools().contains { $0.toolDefinition.name == "read_file" })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("f-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: WorkspaceError.self) { try await m2.add(file) }
    }

    @Test("bare-property tool schemas are turned into valid JSON Schema")
    func schemaNormalised() {
        let bare = Tool(name: "t", description: "d", inputSchema: .object(["path": .object(["type": "string"])]))
        guard case .object(let s) = bare.withValidSchema.inputSchema else { Issue.record("not object"); return }
        #expect(s["type"] == "object")
        if case .object(let p)? = s["properties"] { #expect(p["path"] != nil) } else { Issue.record("no properties") }
        let valid = Tool(name: "t", description: "d", inputSchema: .object(["type": "object", "properties": .object([:])]))
        #expect(valid.withValidSchema.inputSchema == valid.inputSchema)
    }

    @Test("removing a project tells the remove handler its id, so its index can be released")
    func removeHandler() async throws {
        let m = manager()
        let removed = LockedList()
        await m.setRemoveHandler { removed.add($0) }
        let record = try await m.add(folder("alpha"))
        await m.remove(record.id)
        #expect(removed.items == [record.id])
    }
}

private final class LockedList: @unchecked Sendable {
    private let l = NSLock(); private var d: [String] = []
    func add(_ s: String) { l.withLock { d.append(s) } }
    var items: [String] { l.withLock { d } }
}
