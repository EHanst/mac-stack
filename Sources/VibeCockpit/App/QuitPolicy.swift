import Foundation

/// Why macOS is asking the app to quit, read from the quit Apple event.
public enum QuitReason: Equatable, Sendable {
    case logout, shutdown, restart
    /// Cmd-Q, the Dock menu, or anything else.
    case other

    /// `appleEventCode` is the enum value of the event's `keyQuitReason` ('why?') parameter, if any.
    public init(appleEventCode: UInt32?) {
        switch appleEventCode {
        case 0x7368_7574: self = .shutdown  // kAEShutDown 'shut'
        case 0x7265_7374: self = .restart   // kAERestart 'rest'
        case 0x726C_676F: self = .logout    // kAEReallyLogOut 'rlgo'
        default: self = .other
        }
    }
}

/// The app is the AI endpoint other tools use, so only the menu-bar "Quit" (or the system logging
/// out, shutting down or restarting) may stop it. Anything else, such as Cmd-Q, hides it instead.
public enum QuitPolicy {
    public enum Decision: Equatable, Sendable {
        case terminate
        case hideAndKeepRunning
    }

    public static func decide(explicitQuit: Bool, reason: QuitReason) -> Decision {
        if explicitQuit || reason != .other { return .terminate }
        return .hideAndKeepRunning
    }
}
