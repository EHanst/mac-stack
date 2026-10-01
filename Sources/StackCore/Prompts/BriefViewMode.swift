import Foundation

/// Which form of the brief the panel shows. Persisted as the raw value; anything unrecognised
/// (including the old "Preview" and "Edit" tabs) opens the editable human form.
public enum BriefViewMode: String, Sendable, CaseIterable {
    case human, machine, json

    public static func from(stored: String) -> BriefViewMode { BriefViewMode(rawValue: stored) ?? .human }
    public var label: String {
        switch self {
        case .human: "Human"
        case .machine: "Machine"
        case .json: "JSON"
        }
    }

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

/// The one reserved line under the brief: a copy or save result wins, then a warning, then the
/// attachment summary. Never empty, so the line keeps its height.
public enum BriefStatusLine {
    public static func text(note: String?, export: String?, warning: String?, attachments: String?) -> String {
        note ?? export ?? warning ?? attachments ?? " "
    }
}

/// Where a brief is in its life, shown as a small chip so the screen can stay still while it advances.
public enum BriefPhase: String, Sendable {
    case draft = "Draft", improved = "Improved"
    public static func of(_ brief: Brief) -> BriefPhase { brief.isEdited ? .improved : .draft }
}
