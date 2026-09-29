import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore

@Suite("Route notices in chat")
@MainActor
struct RouteNoticeTextTests {
    private func text(_ kind: RouteNotice.Kind, _ load: SystemLoad = SystemLoad()) -> String? {
        AppServices.noticeText(RouteNotice(kind: kind), load: load)
    }

    @Test("a fallback says what happened and where the answer came from")
    func fallback() {
        #expect(text(.fellBack(from: "local:bonsai", to: "openai", reason: "stub failure"))
                == "The model on this Mac couldn't answer (stub failure), so this reply comes from openai in the cloud.")
    }

    @Test("a cloud answer is explained only when the Mac's condition is the reason")
    func governorReason() {
        #expect(text(.using("openai")) == nil)
        #expect(text(.using("local:bonsai"), SystemLoad(memory: .warning)) == nil)
        #expect(text(.using("openai"), SystemLoad(memory: .warning)) == "This Mac is low on memory, so this reply comes from openai in the cloud.")
    }

    @Test("the notice becomes a chat line")
    func reducer() {
        let coordinator = AppCoordinator()
        coordinator.send(.noticeShown("hello"))
        #expect(coordinator.state.intentHistory.last?.kind == .notice)
        #expect(coordinator.state.intentHistory.last?.content == "hello")
    }
}
