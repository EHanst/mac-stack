import Testing
import Foundation
import MCP
@testable import StackMCP
@testable import StackCore

@Suite("Brief tools")
struct BriefToolsTests {
    private func brief(_ title: String, goal: String, id: String = UUID().uuidString) -> Brief {
        var b = Brief.new(title: title, target: .make(modelFamily: "claude", surface: .claudeCode))
        b.id = id
        b.input = goal
        return b
    }
    private func run(_ tool: any AgentToolHandler, _ args: [String: Value] = [:]) async throws -> String {
        let out = try await tool.execute(arguments: args)
        guard case .text(let t, _, _) = out.first else { return "" }
        return t
    }

    @Test("briefs permission is off for a new client and needed by both tools")
    func scope() {
        #expect(!ClientScope.defaultForNewClient.contains(.briefs))
        #expect(ListBriefsTool(provider: { [] }).requiredScope == .briefs)
        #expect(GetBriefTool(provider: { [] }).requiredScope == .briefs)
    }

    @Test("list shows id and title, newest first; empty says so")
    func list() async throws {
        var older = brief("Old", goal: "a", id: "old"); older.updatedAt = Date(timeIntervalSince1970: 0)
        let old = older
        let new = brief("New", goal: "b", id: "new")
        let text = try await run(ListBriefsTool(provider: { [old, new] }))
        #expect(text.hasPrefix("new — New"))
        #expect(text.contains("old — Old"))
        #expect(try await run(ListBriefsTool(provider: { [] })).contains("no briefs"))
    }

    @Test("get returns the compiled prompt with secrets redacted")
    func get() async throws {
        let b = brief("T", goal: "Upload with key AKIAIOSFODNN7EXAMPLE", id: "x")
        let text = try await run(GetBriefTool(provider: { [b] }), ["id": "x"])
        #expect(text.contains("Upload with key"))
        #expect(!text.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    @Test("unknown id, missing id and empty brief give plain answers")
    func edges() async throws {
        let tool = GetBriefTool(provider: { [brief("T", goal: "", id: "e")] })
        #expect(try await run(tool, ["id": "nope"]).contains("No brief with id nope"))
        #expect(try await run(tool, ["id": "e"]).contains("is empty"))
        await #expect(throws: (any Error).self) { _ = try await tool.execute(arguments: [:]) }
    }
}
