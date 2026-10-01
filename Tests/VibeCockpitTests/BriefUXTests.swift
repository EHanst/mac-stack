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

    @Test func templatesAreNotEmptyAndContainAcceptanceCriteria() {
        for template in BriefTemplate.allCases {
            #expect(!template.markdown.isEmpty)
            #expect(template.markdown.contains("Acceptance criteria"))
        }
    }
}
