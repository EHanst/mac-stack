import Foundation
import os

/// What happened to one generation request. Deliberately has no field for prompt or answer text:
/// the log (and the support bundle built from it) can be shared without leaking a conversation.
public struct RequestRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    public var id = UUID()
    public var date: Date                 // when it started
    public var source: String             // "app", "api" or "background"
    public var provider: ProviderID
    public var isLocal: Bool
    public var fellBackFrom: ProviderID?
    public var promptTokens: Int
    public var completionTokens: Int
    public var timeToFirstToken: Double?  // seconds
    public var totalTime: Double          // seconds
    public var outcome: Outcome
    public var error: String?
    public var memory: String             // "normal" / "warning" / "critical" when it started
    public var thermal: String
    public var lowPowerMode: Bool

    public init(date: Date, source: String, provider: ProviderID, isLocal: Bool, fellBackFrom: ProviderID? = nil,
                promptTokens: Int, completionTokens: Int, timeToFirstToken: Double?, totalTime: Double,
                outcome: Outcome, error: String? = nil,
                memory: String = "normal", thermal: String = "nominal", lowPowerMode: Bool = false) {
        self.date = date; self.source = source; self.provider = provider; self.isLocal = isLocal
        self.fellBackFrom = fellBackFrom; self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.timeToFirstToken = timeToFirstToken; self.totalTime = totalTime; self.outcome = outcome
        self.error = error; self.memory = memory; self.thermal = thermal; self.lowPowerMode = lowPowerMode
    }

    /// Words per second after the first one arrived; nil when it can't be told.
    public var tokensPerSecond: Double? {
        guard let ttft = timeToFirstToken, completionTokens > 1, totalTime - ttft > 0.05 else { return nil }
        return Double(completionTokens) / (totalTime - ttft)
    }
}

/// The most recent requests, newest last. Kept in memory and mirrored to a file so a support
/// bundle taken after a restart still shows what happened.
public actor RequestLog {
    private let capacity: Int
    private let fileURL: URL?
    private var records: [RequestRecord]

    public init(capacity: Int = 200, fileURL: URL? = nil) {
        self.capacity = capacity
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            do {
                records = try decoder.decode([RequestRecord].self, from: data)
            } catch {
                // Keep the unreadable file next to the log: the next record() would overwrite it.
                let aside = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                Logger(subsystem: "com.vibecockpit", category: "RequestLog")
                    .error("Request log unreadable, kept as \(aside.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                records = []
            }
        } else {
            records = []
        }
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/request-log.json")
    }

    public func record(_ r: RequestRecord) {
        records.append(r)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        persist()
    }

    public var recent: [RequestRecord] { records }
    public var last: RequestRecord? { records.last }

    public func clear() { records.removeAll(); persist() }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Logger(subsystem: "com.vibecockpit", category: "RequestLog")
                .error("Request log not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// "Why was that slow?" in plain words, from what was measured — never a guess about the model.
public enum SlowReason {
    /// Findings for `record`, judged against the requests before it. Always returns at least one line.
    public static func explain(_ record: RequestRecord, earlier: [RequestRecord]) -> [String] {
        var out: [String] = []

        if record.outcome == .failed {
            out.append("It failed" + (record.error.map { ": \($0)" } ?? "."))
        }
        if let from = record.fellBackFrom {
            out.append("The model on this Mac couldn't answer, so it went to \(record.provider) after trying \(from). That adds the failed attempt to the wait.")
        } else if !record.isLocal {
            out.append("It ran in the cloud (\(record.provider)), so speed depends on the network and the provider.")
        }

        if let ttft = record.timeToFirstToken, ttft >= 3 {
            let secs = String(format: "%.1f", ttft)
            if record.promptTokens >= 4000 {
                out.append("The first word took \(secs) s because the conversation is long (about \(record.promptTokens.formatted()) tokens); the model reads all of it first. A new chat starts faster.")
            } else {
                out.append("The first word took \(secs) s with a short prompt, so the wait was before it started: the model loading, or another request running.")
            }
        }

        // Another request was using the model when this one started.
        if let busy = earlier.last(where: { $0.date < record.date && $0.date.addingTimeInterval($0.totalTime) > record.date }) {
            out.append("Another request (from \(busy.source)) was still running when this one started, and the model handles one at a time.")
        }

        var strained: [String] = []
        if record.memory == "critical" { strained.append("very short on memory") }
        else if record.memory == "warning" { strained.append("low on memory") }
        if record.thermal == "serious" || record.thermal == "critical" { strained.append("running hot") }
        if record.lowPowerMode { strained.append("in Low Power Mode") }
        if !strained.isEmpty {
            out.append("This Mac was \(strained.joined(separator: " and ")) at the time, which slows local models.")
        }

        if record.isLocal, let tps = record.tokensPerSecond {
            let peers = earlier.filter { $0.isLocal && $0.provider == record.provider }.compactMap(\.tokensPerSecond).sorted()
            if peers.count >= 3 {
                let median = peers[peers.count / 2]
                if tps < median * 0.7 {
                    out.append(String(format: "It wrote %.1f words per second, slower than your usual %.1f for this model.", tps, median))
                }
            }
        }

        if out.isEmpty {
            var line = "Nothing unusual found"
            if let tps = record.tokensPerSecond, let ttft = record.timeToFirstToken {
                line += String(format: ": first word after %.1f s, then %.1f words per second.", ttft, tps)
            } else { line += "." }
            out.append(line)
        }
        return out
    }
}
