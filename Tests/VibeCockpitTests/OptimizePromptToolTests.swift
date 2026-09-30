import Foundation
import MCP
import Testing
@testable import StackCore
@testable import StackMCP

@Suite("OptimizePromptTool mode")
struct OptimizePromptToolModeTests {
    @Test("absent mode is improve")
    func absent() throws {
        let mode = try OptimizePromptTool.mode(from: [:])
        #expect(mode == .improve)
    }

    @Test("known modes parse")
    func known() throws {
        #expect(try OptimizePromptTool.mode(from: ["mode": .string("improve")]) == .improve)
        #expect(try OptimizePromptTool.mode(from: ["mode": .string("expand")]) == .expand)
        #expect(try OptimizePromptTool.mode(from: ["mode": .string("adapt")]) == .adapt)
    }

    @Test("unknown mode is an explicit invalidArgument error")
    func unknown() {
        #expect(throws: AgentToolError.self) {
            _ = try OptimizePromptTool.mode(from: ["mode": .string("synthesize")])
        }
    }

    @Test("a mode that is not a string is an invalidArgument error, not improve")
    func nonString() {
        #expect(throws: AgentToolError.self) {
            _ = try OptimizePromptTool.mode(from: ["mode": .int(3)])
        }
    }
}
