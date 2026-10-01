import Testing
import Foundation
@testable import StackCore

@Suite("TargetProfile")
struct TargetProfileTests {
    @Test("Claude Code reads files itself, so it gets references; ChatGPT web gets the text inline")
    func contextModes() {
        #expect(Surface.claudeCode.defaultContextMode == .reference)
        #expect(Surface.cursor.defaultContextMode == .reference)
        #expect(Surface.chatGPTWeb.defaultContextMode == .inline)
        #expect(Surface.claudeDesktop.defaultContextMode == .inline)
        #expect(Surface.other.defaultContextMode == .inline)
    }

    @Test("the model family sets structure and the token budget")
    func familyDrivesStructure() {
        let claude = TargetProfile.make(modelFamily: "claude", surface: .claudeCode)
        #expect(claude.structure == .xmlTags)
        #expect(claude.tokenBudget == ModelPromptProfile.claude.maxUsefulTokens)
        let gpt = TargetProfile.make(modelFamily: "gpt", surface: .chatGPTWeb)
        #expect(gpt.structure == .markdown)
    }

    @Test("an unknown family falls back to the generic profile")
    func unknownFamily() {
        let t = TargetProfile.make(modelFamily: "mystery", surface: .other)
        #expect(t.model == .generic)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let t = TargetProfile.make(modelFamily: "claude", surface: .cursor)
        let back = try JSONDecoder().decode(TargetProfile.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}
