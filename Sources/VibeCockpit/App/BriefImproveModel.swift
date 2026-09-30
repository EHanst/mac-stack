import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Coordinates the Improve sheet across the center column and right pane.
@MainActor
@Observable
public final class BriefImproveModel {
    public var presentedBriefID: String?

    public func open(_ brief: Brief, studio: PromptStudioModel) {
        guard !brief.effectiveBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !studio.isRunning else { return }
        studio.startOptimize(draft: brief.effectiveBody, mode: .improve,
                             intent: PromptEngineer.Intent.general.rawValue)
        presentedBriefID = brief.id
    }

    public func close() {
        presentedBriefID = nil
    }
}
