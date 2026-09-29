import Foundation
import Observation
#if SWIFT_PACKAGE
import VibeCockpitCore
#endif
import Sparkle

/// Software updates through Sparkle. Deliberately quiet: nothing contacts the update server unless
/// the user asks ("Check for Updates…") or turns on daily checks, because this app promises to
/// keep your work on your Mac and an unprompted network call would break that feel.
@MainActor
@Observable
public final class UpdaterModel {
    /// False until a real update-signing key is in Info.plist (see docs/RELEASING.md).
    public let isConfigured: Bool
    public private(set) var automaticChecks: Bool
    private let controller: SPUStandardUpdaterController?

    public init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = UpdateKey.isReal(key)
        if isConfigured {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            automaticChecks = controller.updater.automaticallyChecksForUpdates
        } else {
            controller = nil
            automaticChecks = false
        }
    }

    public func checkForUpdates() { controller?.checkForUpdates(nil) }

    public func setAutomaticChecks(_ on: Bool) {
        guard let controller else { return }
        controller.updater.automaticallyChecksForUpdates = on
        automaticChecks = on
    }
}
