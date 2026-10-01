import Testing
@testable import StackCore

@Suite("MarkdownBlocks")
struct MarkdownBlocksTests {
    @Test func parsesHeadings() {
        let blocks = MarkdownBlocks.parse("# Title\n## Sub\n### Deep")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Sub"),
            .heading(level: 3, text: "Deep")
        ])
    }

    @Test func parsesBulletList() {
        let blocks = MarkdownBlocks.parse("- one\n- two\n* three")
        #expect(blocks == [.bullet(items: ["one", "two", "three"])])
    }

    @Test func parsesNumberedList() {
        let blocks = MarkdownBlocks.parse("1. first\n2. second\n3. third")
        #expect(blocks == [.numbered(items: ["first", "second", "third"])])
    }

    @Test func parsesFencedCodeBlock() {
        let blocks = MarkdownBlocks.parse("```swift\nlet x = 1\n```")
        #expect(blocks == [.code(language: "swift", text: "let x = 1")])
    }

    @Test func parsesBlockquote() {
        let blocks = MarkdownBlocks.parse("> hello\n> world")
        #expect(blocks == [.quote(text: "hello\nworld")])
    }

    @Test func parsesHorizontalRule() {
        var blocks = MarkdownBlocks.parse("---")
        #expect(blocks == [.rule])

        blocks = MarkdownBlocks.parse("***")
        #expect(blocks == [.rule])

        blocks = MarkdownBlocks.parse("___")
        #expect(blocks == [.rule])
    }

    @Test func parsesParagraphs() {
        let blocks = MarkdownBlocks.parse("A paragraph\nwith two lines.\n\nNext paragraph.")
        #expect(blocks == [
            .paragraph(text: "A paragraph\nwith two lines."),
            .paragraph(text: "Next paragraph.")
        ])
    }
}
