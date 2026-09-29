import Foundation
import Observation
#if SWIFT_PACKAGE
import StackCore
#endif

/// Settings view of the request log: recent replies, "why was it slow?", and the support bundle.
@MainActor
@Observable
public final class DiagnosticsModel {
    public private(set) var recent: [RequestRecord] = []   // newest first
    public private(set) var exportError: String?
    private let log: RequestLog
    private let makeBundle: @Sendable () async throws -> Data

    public init(log: RequestLog, makeBundle: @escaping @Sendable () async throws -> Data) {
        self.log = log
        self.makeBundle = makeBundle
    }

    public func reload() async { recent = Array((await log.recent).reversed().prefix(10)) }
    public func clear() async { await log.clear(); await reload() }

    /// Findings for one request, judged against the ones before it.
    public func explanation(for record: RequestRecord) -> [String] {
        let earlier = recent.filter { $0.date < record.date }.sorted { $0.date < $1.date }
        return SlowReason.explain(record, earlier: earlier)
    }

    /// One line per request for the list.
    public nonisolated static func summary(_ r: RequestRecord) -> String {
        var parts = [r.isLocal ? "On this Mac" : "Cloud (\(r.provider))", r.source]
        switch r.outcome {
        case .failed: parts.append("failed")
        case .cancelled: parts.append("stopped")
        case .completed:
            if let t = r.timeToFirstToken { parts.append(String(format: "first word %.1f s", t)) }
            if let s = r.tokensPerSecond { parts.append(String(format: "%.0f words/s", s)) }
        }
        return parts.joined(separator: " · ")
    }

    public func exportBundle(to url: URL) async {
        exportError = nil
        do { try await makeBundle().write(to: url, options: .atomic) }
        catch { exportError = error.localizedDescription }
    }
}
