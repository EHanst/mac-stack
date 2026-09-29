import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("FTSQuery")
struct FTSQueryTests {

    @Test("natural-language question becomes OR-ed prefix terms without stopwords")
    func naturalLanguage() {
        let m = FTSQuery.match("how do we cut prefill at message boundaries")
        #expect(m == "\"cut\"* OR \"prefill\"* OR \"message\"* OR \"boundaries\"*")
    }

    @Test("camelCase identifiers keep the whole word and add their parts")
    func camelCase() {
        let terms = FTSQuery.terms(from: "PrefillPlan chunks InferenceScheduler")
        #expect(terms.contains("prefillplan") && terms.contains("prefill") && terms.contains("plan"))
        #expect(terms.contains("inferencescheduler") && terms.contains("inference") && terms.contains("scheduler"))
    }

    @Test("FTS syntax characters in the query cannot break the expression")
    func specialCharacters() {
        let m = FTSQuery.match("foo\" AND (bar) NEAR* -baz:qux")
        #expect(m != nil)
        #expect(!(m ?? "").contains("("))
        #expect(!(m ?? "").contains(":"))
    }

    @Test("empty or all-stopword queries yield nil")
    func empty() {
        #expect(FTSQuery.match("") == nil)
        #expect(FTSQuery.match("how do we") == nil)
    }

    @Test("terms are capped at 12")
    func capped() {
        let q = (0..<40).map { "word\($0)" }.joined(separator: " ")
        #expect(FTSQuery.terms(from: q).count == 12)
    }
}
