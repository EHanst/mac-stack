import Foundation
import Observation
import ServiceManagement

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but macOS wants the user to approve it in System Settings → Login Items.
    case requiresApproval
    /// Can't be registered (e.g. running from a build folder instead of an installed app).
    case unavailable
}

public protocol LoginItemControlling: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// The real thing: the app registers itself as a login item through `SMAppService`.
public struct SystemLoginItem: LoginItemControlling {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// State behind the "Launch at login" switch. The controller is injected so tests never touch the
/// user's actual login items.
@MainActor
@Observable
public final class LoginItemModel {
    public private(set) var status: LoginItemStatus
    public private(set) var message: String?
    private let controller: any LoginItemControlling

    public init(controller: any LoginItemControlling = SystemLoginItem()) {
        self.controller = controller
        self.status = controller.status
    }

    /// The switch is "on" when registered, including while approval is pending.
    public var isOn: Bool { status == .enabled || status == .requiresApproval }
    public var isAvailable: Bool { status != .unavailable }

    public func refresh() { status = controller.status }

    public func setEnabled(_ on: Bool) {
        message = nil
        do {
            if on { try controller.register() } else { try controller.unregister() }
        } catch {
            message = "Couldn't change the login item: \(error.localizedDescription)"
        }
        status = controller.status
        if status == .requiresApproval {
            message = "Approve VibeCockpit in System Settings → General → Login Items to finish."
        } else if on && status == .unavailable {
            message = "Launch at login works once VibeCockpit is installed in your Applications folder."
        }
    }
}
