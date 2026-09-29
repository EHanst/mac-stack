#if SWIFT_PACKAGE
import StackCore
#endif

/// Plain-language names for the three privacy positions (menu bar and Settings share them).
extension RoutingPolicy: Identifiable {
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .localOnly:    "Only on this Mac"
        case .localFirst:   "On this Mac, cloud if needed"
        case .cloudAllowed: "Cloud allowed"
        }
    }

    public var summary: String {
        switch self {
        case .localOnly:    "Nothing ever leaves this Mac. If the local model can't answer, you get an error instead."
        case .localFirst:   "Uses the model on this Mac. Only if it can't answer will a cloud provider you added be used."
        case .cloudAllowed: "Also uses your cloud provider on its own for long conversations or when this Mac is low on memory."
        }
    }
}
