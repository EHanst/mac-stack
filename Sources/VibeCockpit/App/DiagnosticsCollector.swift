import Foundation
#if canImport(MetricKit)
import MetricKit
#endif
import os

/// Keeps crash and hang reports macOS hands the app (MetricKit) as files on this Mac. Nothing is
/// sent anywhere; they only leave if the user exports a support bundle.
public final class DiagnosticsCollector: NSObject, @unchecked Sendable {
    public static let shared = DiagnosticsCollector()
    private let log = Logger(subsystem: "com.vibecockpit", category: "Diagnostics")

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/Diagnostics", isDirectory: true)
    }

    public func start() {
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }

    /// Newest last; at most `limit`.
    public static func savedReports(limit: Int = 5) -> [(file: String, json: String)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = urls.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        return sorted.suffix(limit).compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
        }
    }

    fileprivate func save(_ data: Data, kind: String) {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try data.write(to: Self.directory.appendingPathComponent("\(kind)-\(stamp).json"), options: .atomic)
            // Keep the folder small: the 30 newest files.
            let all = Self.savedReports(limit: 1000)
            if all.count > 30 {
                for old in all.prefix(all.count - 30) { try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(old.file)) }
            }
        } catch {
            log.error("couldn't save \(kind, privacy: .public) report: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#if canImport(MetricKit)
extension DiagnosticsCollector: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { save(p.jsonRepresentation(), kind: "metrics") }
    }
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { save(p.jsonRepresentation(), kind: "diagnostics") }
    }
}
#endif
