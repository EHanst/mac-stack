import Foundation

public enum BriefTemplate: String, CaseIterable, Sendable {
    case debug = "Debug"
    case refactor = "Refactor"
    case feature = "Feature"

    public var markdown: String {
        switch self {
        case .debug:
            return """
            ## Goal
            <what are you debugging, and why>

            ## Current behaviour
            <what happens now>

            ## Wanted behaviour
            <what should happen instead>

            ## Constraints
            <files, tools, rules, things not to change>

            ## Acceptance criteria
            <checkable outcomes>

            ## How to verify
            <commands, steps, expected output>

            ## Output format
            <what the reply should include>
            """
        case .refactor:
            return """
            ## Goal
            <what are you refactoring, and why>

            ## Current behaviour
            <how it works now>

            ## Wanted behaviour
            <how it should work after the refactor>

            ## Constraints
            <files, tools, rules, things not to change>

            ## Acceptance criteria
            <checkable outcomes>

            ## How to verify
            <commands, steps, expected output>

            ## Output format
            <what the reply should include>
            """
        case .feature:
            return """
            ## Goal
            <what feature should be built, and why>

            ## Current behaviour
            <what exists now>

            ## Wanted behaviour
            <what the new feature should do>

            ## Constraints
            <files, tools, rules, things not to change>

            ## Acceptance criteria
            <checkable outcomes>

            ## How to verify
            <commands, steps, expected output>

            ## Output format
            <what the reply should include>
            """
        }
    }
}
