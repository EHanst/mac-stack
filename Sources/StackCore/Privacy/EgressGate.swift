import Foundation

/// Why the app is about to contact the internet.
public enum EgressPurpose: String, Codable, Sendable {
    case cloudInference   // a brief or draft goes to a cloud model to be improved
    case modelDownload    // the user installed a model (weights come down, nothing goes up)
    case updateCheck      // the user asked whether a newer version exists (nothing goes up)
}

/// One line of the "what left this Mac" record. Never contains prompt text or answers.
public struct EgressEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var date: Date
    public let purpose: EgressPurpose
    public let host: String
    /// The cloud provider's name for inference calls.
    public let provider: String?
    public let blocked: Bool
    public let reason: String?
    /// Identical consecutive entries are merged and counted.
    public var count: Int
}

public enum EgressError: LocalizedError, Sendable, Equatable {
    case blockedByPrivacy(host: String)
    case budgetExhausted(usedTokens: Int, capTokens: Int)

    public var errorDescription: String? {
        switch self {
        case .blockedByPrivacy(let host):
            "Blocked: Kokoro is set to \"Only on this Mac\", so nothing was sent to \(host)."
        case .budgetExhausted(let used, let cap):
            "The monthly cloud limit is reached (\(used.formatted()) of \(cap.formatted()) tokens). Raise it in Settings or wait until next month."
        }
    }
}

public struct EgressState: Codable, Sendable, Equatable {
    public var entries: [EgressEntry] = []
    /// Cloud tokens used per month, keyed "yyyy-MM".
    public var monthlyTokens: [String: Int] = [:]
    public var monthlyTokenCap: Int?
    public init() {}

    private enum CodingKeys: String, CodingKey { case entries, monthlyTokens, monthlyTokenCap }

    /// Lines written for purposes the app no longer has (web reads and searches) are dropped on load;
    /// the rest of the record is kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var list = try c.nestedUnkeyedContainer(forKey: .entries)
        while !list.isAtEnd {
            if let entry = try? list.decode(EgressEntry.self) { entries.append(entry) }
            else { _ = try? list.decode(Discarded.self) }
        }
        monthlyTokens = try c.decodeIfPresent([String: Int].self, forKey: .monthlyTokens) ?? [:]
        monthlyTokenCap = try c.decodeIfPresent(Int.self, forKey: .monthlyTokenCap)
    }

    private struct Discarded: Decodable {}
}

public protocol EgressStore: Sendable {
    func load() -> EgressState
    func save(_ state: EgressState)
}

public struct FileEgressStore: EgressStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit/egress.json")
    }
    public func load() -> EgressState {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(EgressState.self, from: Data(contentsOf: url))) ?? EgressState()
    }
    public func save(_ state: EgressState) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".egress-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}

/// The one place every outbound request passes: enforces "Only on this Mac", enforces the monthly
/// cloud limit, and records what left (host and purpose only).
public actor EgressGate {

    public static let maxEntries = 500

    private var policy: RoutingPolicy
    private var state: EgressState
    private let store: any EgressStore
    private let now: @Sendable () -> Date

    public init(policy: RoutingPolicy = .localFirst, store: any EgressStore = FileEgressStore(url: FileEgressStore.defaultURL()),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = policy
        self.store = store
        self.state = store.load()
        self.now = now
    }

    public func setPolicy(_ policy: RoutingPolicy) { self.policy = policy }

    // MARK: Authorising

    /// Call before every request. Throws (and records the refusal) when the request isn't allowed.
    public func authorize(_ purpose: EgressPurpose, url: URL, provider: String? = nil) throws {
        let host = url.host ?? url.absoluteString
        if policy == .localOnly, purpose != .modelDownload, purpose != .updateCheck {
            log(purpose, host, provider, blocked: true, reason: "Only on this Mac")
            throw EgressError.blockedByPrivacy(host: host)
        }
        if purpose == .cloudInference, let cap = state.monthlyTokenCap {
            let used = tokensThisMonth
            if used >= cap {
                log(purpose, host, provider, blocked: true, reason: "Monthly limit reached")
                throw EgressError.budgetExhausted(usedTokens: used, capTokens: cap)
            }
        }
        log(purpose, host, provider, blocked: false, reason: nil)
    }

    /// Would a cloud request be allowed right now? (No record is written.)
    public func cloudAllowed() -> EgressError? {
        if policy == .localOnly { return .blockedByPrivacy(host: "the cloud") }
        if let cap = state.monthlyTokenCap, tokensThisMonth >= cap { return .budgetExhausted(usedTokens: tokensThisMonth, capTokens: cap) }
        return nil
    }

    // MARK: Budget (tokens, not dollars: prices differ per model and change)

    private var monthKey: String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public var tokensThisMonth: Int { state.monthlyTokens[monthKey] ?? 0 }
    public var monthlyTokenCap: Int? { state.monthlyTokenCap }

    public func setMonthlyTokenCap(_ cap: Int?) {
        state.monthlyTokenCap = (cap ?? 0) > 0 ? cap : nil
        store.save(state)
    }

    public func recordCloudTokens(_ tokens: Int) {
        guard tokens > 0 else { return }
        state.monthlyTokens[monthKey, default: 0] += tokens
        store.save(state)
    }

    // MARK: Ledger

    public var entries: [EgressEntry] { state.entries }

    public func clearLedger() { state.entries = []; store.save(state) }

    private func log(_ purpose: EgressPurpose, _ host: String, _ provider: String?, blocked: Bool, reason: String?) {
        let date = now()
        if var last = state.entries.last, last.purpose == purpose, last.host == host, last.blocked == blocked,
           last.provider == provider, date.timeIntervalSince(last.date) < 60 {
            last.count += 1; last.date = date
            state.entries[state.entries.count - 1] = last
        } else {
            state.entries.append(EgressEntry(id: UUID(), date: date, purpose: purpose, host: host, provider: provider,
                                             blocked: blocked, reason: reason, count: 1))
            if state.entries.count > Self.maxEntries { state.entries.removeFirst(state.entries.count - Self.maxEntries) }
        }
        store.save(state)
    }
}
