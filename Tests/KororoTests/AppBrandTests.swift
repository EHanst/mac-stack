import Testing
@testable import KororoCore

@Suite("AppBrand")
struct AppBrandTests {
    @Test("the app is called Kororo and describes itself as a prompt sidecar")
    func names() {
        #expect(AppBrand.name == "Kororo")
        #expect(AppBrand.tagline == "Prompt sidecar")
    }

    @Test("the first-run menu-bar status uses the brand name")
    func onboardingStatus() {
        let s = MenuBarStatus.make(models: [], onboardingNeeded: true)
        #expect(s.title == "Set up \(AppBrand.name)")
    }
}
