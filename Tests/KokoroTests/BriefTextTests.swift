import Testing
@testable import StackCore

@Suite("BriefText and numbering")
struct BriefTextTests {
    @Test func stripsLeakedReplyTags() {
        #expect(BriefText.stripStrayTags("Do the thing.\n</changes>") == "Do the thing.")
        #expect(BriefText.stripStrayTags("Do it.\n<changes>\n- one line\n</changes>\n<questions>\n</questions>") == "Do it.")
        #expect(BriefText.stripStrayTags("Step\n</chang") == "Step")
        #expect(BriefText.stripStrayTags("a < b and <div>") == "a < b and <div>")
    }

    @Test func optimizerParseNeverKeepsChangesTag() {
        let raw = "<improved>\n1. a\n1. b\n</changes>\n</improved>\n<changes>\n- x\n</changes>"
        let parsed = PromptOptimizer.parse(raw)
        #expect(!parsed.improved.contains("changes"))
        #expect(parsed.improved == "1. a\n2. b")
    }

    @Test func renumberKeepsDepthsAndSkipsCode() {
        let text = "1. a\n   1. x\n   1. y\n1. b\n```\n1. keep\n1. keep\n```"
        #expect(MarkdownNumbering.renumber(text) == "1. a\n   1. x\n   2. y\n2. b\n```\n1. keep\n1. keep\n```")
    }
}
