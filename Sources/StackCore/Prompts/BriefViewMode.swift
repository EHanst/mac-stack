import Foundation

/// Which form of the brief the panel shows. Persisted as the raw value; anything unrecognised
/// (including the old "Preview" and "Edit" tabs) opens the editable human form.
public enum BriefViewMode: String, Sendable, CaseIterable {
    case human, machine

    public static func from(stored: String) -> BriefViewMode { BriefViewMode(rawValue: stored) ?? .human }
    public var label: String { self == .human ? "Human" : "Machine" }

    /// One line saying why the machine form looks the way it does, e.g. "Claude · XML tags".
    public static func machineCaption(for target: TargetProfile) -> String {
        let shape: String
        switch target.structure {
        case .xmlTags: shape = "XML tags"
        case .markdown: shape = "Markdown"
        case .plainNumbered: shape = "plain markers"
        }
        return "\(target.model.displayName) · \(shape)"
    }
}
