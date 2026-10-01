import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// "Is there a newer version?" Off unless asked: a manual check, or an opt-in daily check that
/// never runs under "Only on this Mac".
@MainActor
@Observable
public final class UpdatesModel {
    public enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case failed(String)
    }

    public static let dailyKey = "updateCheckDaily"
    static let lastCheckKey = "updateLastCheck"

    public private(set) var status: Status = .idle
    public private(set) var automaticChecks: Bool
    private let defaults: UserDefaults
    private let currentVersion: String
    private let checker: @Sendable () async -> UpdateChecker
    private let now: @Sendable () -> Date

    public init(defaults: UserDefaults = .standard,
                currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                checker: @escaping @Sendable () async -> UpdateChecker = { UpdateChecker() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.checker = checker
        self.now = now
        self.automaticChecks = defaults.bool(forKey: Self.dailyKey)
    }

    public func setAutomaticChecks(_ on: Bool) {
        automaticChecks = on
        defaults.set(on, forKey: Self.dailyKey)
    }

    /// The user asked. Allowed under every privacy setting (and recorded in the ledger).
    public func checkNow() async {
        guard status != .checking else { return }
        status = .checking
        do {
            status = try await checker().check(currentVersion: currentVersion).asStatus
        } catch {
            status = .failed(error.localizedDescription)
        }
        defaults.set(now(), forKey: Self.lastCheckKey)
    }

    /// Called at launch and while running. Does nothing unless the user opted in, a day has passed,
    /// and the privacy setting isn't "Only on this Mac".
    public func checkIfDue(policy: RoutingPolicy) async {
        guard automaticChecks, policy != .localOnly else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now().timeIntervalSince(last) < 24 * 3600 { return }
        await checkNow()
    }

    public var statusLine: String? {
        switch status {
        case .idle, .checking: nil
        case .upToDate: "You're up to date (version \(currentVersion))."
        case .available(let info): "Version \(info.version) is available (you have \(currentVersion))."
        case .failed(let message): "Couldn't check: \(message)"
        }
    }
}

private extension UpdateCheckResult {
    var asStatus: UpdatesModel.Status {
        switch self {
        case .upToDate: .upToDate
        case .available(let info): .available(info)
        }
    }
}
