import Testing
import Foundation
@testable import StackCore

@Suite("KnowledgeSettings")
struct KnowledgeSettingsTests {
    func settings() -> KnowledgeSettings {
        KnowledgeSettings(defaults: UserDefaults(suiteName: "ks-\(UUID().uuidString)")!)
    }

    @Test("default is undecided, not recording, card shown")
    func defaults() {
        let s = settings()
        #expect(s.decision == .undecided)
        #expect(!s.isRecording)
        #expect(s.prompt == .card)
    }

    @Test("Not now hides the card; the first accepted brief shows the nudge")
    func cardThenNudge() {
        let s = settings()
        s.dismissCard()
        #expect(s.prompt == nil)
        s.noteAcceptEvent(briefID: "a")
        #expect(s.prompt == .nudge)
    }

    @Test("a dismissed nudge returns once, after 5 accepted briefs, then never")
    func nudgeSchedule() {
        let s = settings()
        s.noteAcceptEvent(briefID: "1")
        #expect(s.prompt == .nudge)
        s.dismissNudge()
        #expect(s.prompt == nil)
        for i in 2...5 { s.noteAcceptEvent(briefID: "\(i)") }
        #expect(s.prompt == nil)
        s.noteAcceptEvent(briefID: "6")
        #expect(s.prompt == .nudge)
        s.dismissNudge()
        for i in 7...30 { s.noteAcceptEvent(briefID: "\(i)") }
        #expect(s.prompt == nil)
    }

    @Test("the same brief accepted repeatedly counts once")
    func distinct() {
        let s = settings()
        for _ in 0..<10 { s.noteAcceptEvent(briefID: "same") }
        #expect(s.acceptedBriefCount == 1)
    }

    @Test("enabling turns recording on and hides every prompt; declined never nudges")
    func decisions() {
        let s = settings()
        s.setDecision(.enabled)
        #expect(s.isRecording)
        #expect(s.prompt == nil)
        s.setDecision(.declined)
        #expect(!s.isRecording)
        s.noteAcceptEvent(briefID: "x")
        #expect(s.prompt == nil)
    }
}
