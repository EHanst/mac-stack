import Testing
@testable import StackCore

struct BriefUXTests {

    @Test func savingsPercentClampsAtZero() {
        #expect(TokenSavings.percent(plain: 100, compact: 200) == 0)
        #expect(TokenSavings.percent(plain: 0, compact: 0) == 0)
    }

    @Test func savingsPercentRounds() {
        #expect(TokenSavings.percent(plain: 200, compact: 100) == 50)
        #expect(TokenSavings.percent(plain: 3, compact: 1) == 67)
    }

    @Test func wordDiffMergeAcceptsAllAndRejectsAll() {
        let original = "a b c"
        let proposed = "a x c"
        let hunks = WordDiff.hunks(from: original, to: proposed)
        #expect(hunks.count == 1)
        let allAccepted = Set(hunks.map(\.id))
        #expect(WordDiff.merge(original: original, proposed: proposed, acceptedHunkIndexes: allAccepted) == proposed)
        #expect(WordDiff.merge(original: original, proposed: proposed, acceptedHunkIndexes: []) == original)
    }

    @Test func wordDiffMergePartialHunk() {
        let original = "a b c"
        let proposed = "a x c"
        let hunk = WordDiff.hunks(from: original, to: proposed)[0]
        #expect(WordDiff.merge(original: original, proposed: proposed, acceptedHunkIndexes: [hunk.id]) == proposed)
    }

    @Test func changesDescribeBeforeAfterAndContext() {
        let changes = WordDiff.changes(from: "one two three four five six", to: "one two THREE four five six seven", contextWords: 2)
        #expect(changes.count == 2)
        #expect(changes[0].kind == .reworded && changes[0].before == "three" && changes[0].after == "THREE")
        #expect(changes[0].lead == "one two" && changes[0].trail == "four five")
        #expect(changes[1].kind == .added && changes[1].after == "seven" && changes[1].before.isEmpty)
        #expect(WordDiff.changes(from: "a b", to: "a").first?.kind == .removed)
        #expect(WordDiff.changes(from: "same", to: "same").isEmpty)
        #expect(changes.map(\.id) == WordDiff.hunks(from: "one two three four five six", to: "one two THREE four five six seven").map(\.id))
    }

    @Test func changesCarrySectionReasonAndLostLiterals() {
        let old = "# Goal\nHandle the cache properly.\n# Steps\nEdit Sources/App/Cache.swift with limit 4096."
        let new = "# Goal\nEvict the least recently used entry.\n# Steps\nEdit the cache file."
        let changes = WordDiff.changes(from: old, to: new)
        #expect(changes.first?.section == "Goal")
        #expect(changes.first?.reason == "Replaces a vague word with something concrete")
        let steps = changes.last
        #expect(steps?.section == "Steps")
        #expect(steps?.lostLiterals.contains("Sources/App/Cache.swift") == true)
        #expect(steps?.lostLiterals.contains("4096") == true)
        #expect(WordDiff.changes(from: "a b", to: "a b ok?").first?.reason == "Marks something missing")
    }

    @Test func nearbyEditsGroupIntoOneChangeAndMergeStaysConsistent() {
        let old = "Handle the cache properly now"
        let new = "Evict the least recently used entry now"
        let changes = WordDiff.changes(from: old, to: new)
        #expect(changes.count == 1 && changes[0].before == "Handle the cache properly" && changes[0].after == "Evict the least recently used entry")
        let ids = Set(changes.map(\.id))
        #expect(WordDiff.merge(original: old, proposed: new, acceptedHunkIndexes: ids) == new)
        #expect(WordDiff.merge(original: old, proposed: new, acceptedHunkIndexes: []) == old)
    }

    @Test func statusLinePicksOneMessageAndNeverGoesEmpty() {
        #expect(BriefStatusLine.text(note: "Copied", export: "Saved", warning: "W", attachments: "A") == "Copied")
        #expect(BriefStatusLine.text(note: nil, export: "Saved", warning: "W", attachments: "A") == "Saved")
        #expect(BriefStatusLine.text(note: nil, export: nil, warning: "W", attachments: "A") == "W")
        #expect(BriefStatusLine.text(note: nil, export: nil, warning: nil, attachments: "A") == "A")
        #expect(BriefStatusLine.text(note: nil, export: nil, warning: nil, attachments: nil) == " ")
    }

    @Test func draftTokensComparesAgainstTheOriginalInput() {
        var brief = Brief.new(title: "t", input: "fix the bug", target: .make(modelFamily: "claude", surface: .other))
        #expect(BriefCompiler.draftTokens(brief) == nil)
        brief.body = "Fix the bug in Sources/App/Cache.swift. Done when tests pass."
        let draft = BriefCompiler.draftTokens(brief)
        #expect(draft != nil && draft! < BriefCompiler.compile(brief).tokens)
    }

    @Test func templatesAreNotEmptyAndContainAcceptanceCriteria() {
        for template in BriefTemplate.allCases {
            #expect(!template.markdown.isEmpty)
            #expect(template.markdown.contains("Acceptance criteria"))
        }
    }

    @Test("stored view mode migrates legacy and unknown values to human")
    func viewModeMigration() {
        #expect(BriefViewMode.from(stored: "machine") == .machine)
        #expect(BriefViewMode.from(stored: "human") == .human)
        for legacy in ["Preview", "Edit", "", "junk"] { #expect(BriefViewMode.from(stored: legacy) == .human) }
        #expect(BriefViewMode.from(stored: "json") == .json)
        #expect(BriefViewMode.human.label == "Human" && BriefViewMode.machine.label == "Machine" && BriefViewMode.json.label == "JSON")
    }

    @Test("machine caption names the model and its structure")
    func machineCaption() {
        #expect(BriefViewMode.machineCaption(for: .make(modelFamily: "claude", surface: .other)) == "Claude · XML tags")
        #expect(BriefViewMode.machineCaption(for: .make(modelFamily: "gpt", surface: .other)) == "GPT · Markdown")
        #expect(BriefViewMode.machineCaption(for: .make(modelFamily: "local", surface: .other)) == "Model on this Mac · plain markers")
    }
}
