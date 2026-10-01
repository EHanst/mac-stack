import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Settings view of the egress gate: this month's cloud use, the limit, and what left this Mac.
@MainActor
@Observable
public final class CloudUsageModel {
    public private(set) var tokensThisMonth = 0
    public private(set) var monthlyTokenCap: Int?
    public private(set) var entries: [EgressEntry] = []
    private let gate: EgressGate

    public init(gate: EgressGate) { self.gate = gate }

    public func reload() async {
        tokensThisMonth = await gate.tokensThisMonth
        monthlyTokenCap = await gate.monthlyTokenCap
        entries = await gate.entries.reversed()
    }

    public func setCap(_ cap: Int?) async {
        await gate.setMonthlyTokenCap(cap)
        await reload()
    }

    public func clearLedger() async {
        await gate.clearLedger()
        await reload()
    }

    /// "Blocked" / "Sent" lines in plain words for the ledger view.
    public static func describe(_ e: EgressEntry) -> String {
        let what: String
        switch e.purpose {
        case .cloudInference: what = "Question to \(e.provider ?? "cloud model")"
        case .modelDownload: what = "Model download"
        case .updateCheck: what = "Update check"
        }
        let times = e.count > 1 ? " ×\(e.count)" : ""
        return e.blocked ? "Blocked: \(what) to \(e.host)\(times)" : "\(what) → \(e.host)\(times)"
    }
}
