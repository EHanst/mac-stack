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
        #expect(blocks == [.list(items: [
            .init(ordered: false, text: "one"), .init(ordered: false, text: "two"), .init(ordered: false, text: "three")])])
    }

    @Test func parsesNumberedList() {
        let blocks = MarkdownBlocks.parse("1. first\n2. second\n3. third")
        #expect(blocks == [.list(items: [
            .init(ordered: true, number: 1, text: "first"), .init(ordered: true, number: 2, text: "second"),
            .init(ordered: true, number: 3, text: "third")])])
    }

    @Test func numbersCountUpWhateverTheSourceSays() {
        guard case .list(let items) = MarkdownBlocks.parse("1. a\n1. b\n1. c").first else { Issue.record("no list"); return }
        #expect(items.map(\.number) == [1, 2, 3])
    }

    @Test func subStepsNestInsteadOfRestartingTheList() {
        let text = "1. First\n   - detail a\n   - detail b\n\n2. Second\n   1. sub one\n   2. sub two\n3. Third"
        let blocks = MarkdownBlocks.parse(text)
        #expect(blocks.count == 1)
        guard case .list(let items) = blocks[0] else { Issue.record("no list"); return }
        #expect(items.map(\.number) == [1, 2, 3])
        #expect(items[0].children.map(\.text) == ["detail a", "detail b"])
        #expect(items[1].children.map(\.number) == [1, 2])
    }

    @Test func wrappedLineJoinsItsItem() {
        guard case .list(let items) = MarkdownBlocks.parse("1. long step\n   keeps going\n2. next").first else { Issue.record("no list"); return }
        #expect(items[0].text == "long step\nkeeps going")
        #expect(items.count == 2)
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
