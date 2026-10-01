import Testing
@testable import KokoroCore

@Suite("DefaultsKey")
struct DefaultsKeyTests {
    @Test("persisted key names do not change and never collide")
    func frozenAndUnique() {
        #expect(DefaultsKey.all.sorted() == [
            "apiSharingEnabled", "apiSharingPort", "appFont", "appTheme", "brief.viewMode",
            "optimizerModelPin", "routingPolicy", "updateCheckDaily", "updateLastCheck",
        ])
        #expect(Set(DefaultsKey.all).count == DefaultsKey.all.count)
    }

    @Test("the keys other types expose are the shared ones")
    @MainActor func aliases() {
        #expect(AppTheme.storageKey == DefaultsKey.appTheme)
        #expect(AppFont.storageKey == DefaultsKey.appFont)
        #expect(APISharingModel.enabledKey == DefaultsKey.apiSharingEnabled)
        #expect(APISharingModel.portKey == DefaultsKey.apiSharingPort)
        #expect(UpdatesModel.dailyKey == DefaultsKey.updateCheckDaily)
        #expect(UpdatesModel.lastCheckKey == DefaultsKey.updateLastCheck)
        #expect(PromptStudioModel.pinKey == DefaultsKey.optimizerModelPin)
    }
}
