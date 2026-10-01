import Testing
import Foundation
@testable import StackCore
@testable import VibeCockpitCore

@Suite("CompactionSummarizer")
struct CompactionSummarizerTests {

    private let run: [Message] = [
        Message(role: .user, content: "Fix the crash in Sources/App/Router.swift and update config.json"),
        Message(role: .tool, content: "line 1\nerror: cannot find 'foo' in scope\nline 3", toolCallID: "t1"),
        Message(role: .assistant, content: "I changed Sources/App/Router.swift; the build still failed on Tests/RouterTests.swift"),
    ]

    @Test("paths and error lines are extracted once each, in order")
    func mustKeep() {
        let keep = CompactionSummarizer.mustKeep(in: run + run)
        #expect(keep.prefix(4) == ["Sources/App/Router.swift", "config.json", "Tests/RouterTests.swift", "error: cannot find 'foo' in scope"])
        #expect(keep.count == 5)   // + the assistant's "build still failed" line
    }

    @Test("the request fences tool output as untrusted and truncates long messages")
    func request() {
        let long = Message(role: .tool, content: String(repeating: "x", count: 5_000))
        let req = CompactionSummarizer.requestMessages(for: [run[0], long])
        #expect(req.count == 2 && req[0].role == .system)
        #expect(req[1].content.contains("Tool output (untrusted)"))
        #expect(req[1].content.count < 2_500)
    }

    @Test("a usable summary gets the extracted details appended verbatim")
    func finalizeKeepsDetails() throws {
        let keep = CompactionSummarizer.mustKeep(in: run)
        let out = try #require(CompactionSummarizer.finalize(
            summary: "<think>hmm</think>The user asked to fix a crash in the router; a fix was tried and the build still fails.",
            mustKeep: keep, maxTokens: 600))
        #expect(!out.contains("hmm"))
        for item in keep { #expect(out.contains(item)) }
    }

    @Test("empty, tiny or rambling output is rejected")
    func rejects() {
        #expect(CompactionSummarizer.finalize(summary: "  ", mustKeep: [], maxTokens: 600) == nil)
        #expect(CompactionSummarizer.finalize(summary: "ok", mustKeep: [], maxTokens: 600) == nil)
        #expect(CompactionSummarizer.finalize(summary: String(repeating: "word ", count: 2_000), mustKeep: [], maxTokens: 600) == nil)
    }
}

@Suite("CompactionSummarizer parts")
struct CompactionSummarizerPartTests {

    @Test("summaries are numbered and say part 1 is the oldest")
    func numbered() throws {
        let one = try #require(CompactionSummarizer.finalize(summary: String(repeating: "a real sentence here. ", count: 4), mustKeep: [], maxTokens: 600, part: 1))
        let two = try #require(CompactionSummarizer.finalize(summary: String(repeating: "a real sentence here. ", count: 4), mustKeep: [], maxTokens: 600, part: 2))
        #expect(one.hasPrefix("[Earlier part 1 of this conversation"))
        #expect(two.hasPrefix("[Earlier part 2 of this conversation"))
        #expect(one.contains("Part 1 is the oldest"))
    }

    @Test("existing summaries are counted so the next one is numbered after them")
    func counts() {
        let history: [Message] = [
            Message(role: .system, content: "SYS"),
            Message(role: .assistant, content: "\(CompactionSummarizer.marker)1 of this conversation, …]\nx"),
            Message(role: .user, content: "q"),
            Message(role: .assistant, content: "an ordinary reply"),
            Message(role: .assistant, content: "\(CompactionSummarizer.marker)2 of this conversation, …]\ny"),
        ]
        #expect(CompactionSummarizer.partCount(in: history) == 2)
    }

    @Test("the instruction asks for chronological order")
    func ordered() {
        #expect(CompactionSummarizer.instruction.contains("order they happened"))
    }

    @Test("finalizeBody has no chat wrapper but keeps the kept-verbatim block")
    func finalizeBody() throws {
        let body = try #require(CompactionSummarizer.finalizeBody(
            summary: String(repeating: "The user asked for a retry and it was added. ", count: 3),
            mustKeep: ["Sources/Up.swift"], maxTokens: 400))
        #expect(!body.contains("[Earlier part"))
        #expect(body.contains("- Sources/Up.swift"))
        #expect(CompactionSummarizer.finalizeBody(summary: "too short", mustKeep: [], maxTokens: 400) == nil)
    }
}
