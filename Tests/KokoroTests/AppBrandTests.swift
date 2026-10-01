import Testing
@testable import KokoroCore

@Suite("AppBrand")
struct AppBrandTests {
    @Test("the app is called Kokoro and describes itself as a prompt sidecar")
    func names() {
        #expect(AppBrand.name == "Kokoro")
        #expect(AppBrand.tagline == "Prompt sidecar")
    }

    @Test("the first-run menu-bar status uses the brand name")
    func onboardingStatus() {
        let s = MenuBarStatus.make(models: [], onboardingNeeded: true)
        #expect(s.title == "Set up \(AppBrand.name)")
    }
}
