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
        let changes = WordDiff.changes(from: "one two three four five", to: "one two THREE four five six", contextWords: 2)
        #expect(changes.count == 2)
        #expect(changes[0].kind == .reworded && changes[0].before == "three" && changes[0].after == "THREE")
        #expect(changes[0].lead == "one two" && changes[0].trail == "four five")
        #expect(changes[1].kind == .added && changes[1].after == "six" && changes[1].before.isEmpty)
        #expect(WordDiff.changes(from: "a b", to: "a").first?.kind == .removed)
        #expect(WordDiff.changes(from: "same", to: "same").isEmpty)
        #expect(changes.map(\.id) == WordDiff.hunks(from: "one two three four five", to: "one two THREE four five six").map(\.id))
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
