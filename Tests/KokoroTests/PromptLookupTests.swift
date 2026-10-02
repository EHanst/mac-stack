import Testing
@testable import StackCore

@Suite("PromptLookup")
struct PromptLookupTests {

    @Test("proposes the tokens that followed the latest earlier occurrence of the trailing n-gram")
    func copiesContinuation() {
        //            0  1  2  3  4  5  6  7 | generated: 1 2
        let context: [Int32] = [9, 1, 2, 3, 4, 5, 8, 7, 1, 2]
        #expect(PromptLookup.draft(context, maxDraft: 3) == [3, 4, 5])
        #expect(PromptLookup.draft(context, maxDraft: 10) == [3, 4, 5, 8, 7, 1, 2])
    }

    @Test("prefers the longest n-gram, then the most recent match")
    func longestThenRecent() {
        // Bigram "1 2" occurs at 0 (→ 7) and at 4 (→ 6); trigram "0 1 2"… only at 3 (→ 6).
        let context: [Int32] = [1, 2, 7, 0, 1, 2, 6, 5, 0, 1, 2]
        #expect(PromptLookup.draft(context, maxDraft: 2) == [6, 5])
        // Without a trigram match the most recent bigram wins.
        let bigrams: [Int32] = [1, 2, 7, 3, 1, 2, 6, 4, 1, 2]
        #expect(PromptLookup.draft(bigrams, maxDraft: 1) == [6])
    }

    @Test("no match, too-short context or zero budget gives no draft")
    func noDraft() {
        #expect(PromptLookup.draft([1, 2, 3, 4, 5], maxDraft: 4).isEmpty)
        #expect(PromptLookup.draft([1], maxDraft: 4).isEmpty)
        #expect(PromptLookup.draft([], maxDraft: 4).isEmpty)
        #expect(PromptLookup.draft([1, 2, 1, 2], maxDraft: 0).isEmpty)
    }

    @Test("a single-token suffix match is not enough")
    func needsTwoTokens() {
        // Only the unigram "5" repeats.
        #expect(PromptLookup.draft([5, 6, 7, 1, 5], maxDraft: 3).isEmpty)
    }

    @Test("the trailing n-gram never matches itself")
    func notItself() {
        #expect(PromptLookup.draft([3, 1, 2], maxDraft: 3).isEmpty)
        // An overlapping earlier occurrence still counts: "1 1" at 0 is followed by 1.
        #expect(PromptLookup.draft([1, 1, 1], maxDraft: 3) == [1])
    }

    @Test("accepted length is the longest prefix of drafts equal to the model's picks")
    func acceptedPrefix() {
        #expect(PromptLookup.acceptedCount(drafts: [4, 5, 6], picks: [4, 5, 6, 7]) == 3)
        #expect(PromptLookup.acceptedCount(drafts: [4, 5, 6], picks: [4, 9, 6, 7]) == 1)
        #expect(PromptLookup.acceptedCount(drafts: [4, 5, 6], picks: [3, 5, 6, 7]) == 0)
        #expect(PromptLookup.acceptedCount(drafts: [], picks: [3]) == 0)
    }
}
