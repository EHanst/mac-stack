import Foundation

/// Everything a support bundle may contain. There is deliberately no place for prompt text,
/// answers, file contents, API keys, tokens, project paths or command lines: anything shared
/// from here can't leak a conversation or a secret.
public struct SupportBundleInput: Sendable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var chip: String
    public var memoryGB: Int
    public var routingPolicy: String
    public var systemLoad: SystemLoad
    public var installedModels: [String]
    public var providers: [Provider]
    public var requests: [RequestRecord]
    public var egress: [EgressEntry]
    public var tokensThisMonth: Int
    public var monthlyTokenCap: Int?
    public var externalServers: [ExternalServer]
    public var projectCount: Int
    public var crashReports: [CrashReport]

    public struct Provider: Sendable, Codable, Equatable { public var id: String; public var isLocal: Bool
        public init(id: String, isLocal: Bool) { self.id = id; self.isLocal = isLocal } }
    public struct ExternalServer: Sendable, Codable, Equatable { public var name: String; public var status: String
        public init(name: String, status: String) { self.name = name; self.status = status } }
    /// A MetricKit diagnostic (crash, hang…) exactly as macOS produced it, capped in size.
    public struct CrashReport: Sendable, Codable, Equatable { public var file: String; public var json: String
        public init(file: String, json: String) { self.file = file; self.json = json } }

    public init(appVersion: String, build: String, osVersion: String, chip: String, memoryGB: Int,
                routingPolicy: String, systemLoad: SystemLoad, installedModels: [String], providers: [Provider],
                requests: [RequestRecord], egress: [EgressEntry], tokensThisMonth: Int, monthlyTokenCap: Int?,
                externalServers: [ExternalServer], projectCount: Int, crashReports: [CrashReport]) {
        self.appVersion = appVersion; self.build = build; self.osVersion = osVersion; self.chip = chip
        self.memoryGB = memoryGB; self.routingPolicy = routingPolicy; self.systemLoad = systemLoad
        self.installedModels = installedModels; self.providers = providers; self.requests = requests
        self.egress = egress; self.tokensThisMonth = tokensThisMonth; self.monthlyTokenCap = monthlyTokenCap
        self.externalServers = externalServers; self.projectCount = projectCount; self.crashReports = crashReports
    }
}

public enum SupportBundle {
    private struct Document: Encodable {
        let generatedAt: Date
        let note = "No prompts, answers, file contents, keys, project paths or command lines are included."
        let app: [String: String]
        let system: [String: String]
        let load: [String: String]
        let routingPolicy: String
        let installedModels: [String]
        let providers: [SupportBundleInput.Provider]
        let cloudUse: CloudUse
        let requests: [RequestRecord]
        let egress: [Egress]
        let externalServers: [SupportBundleInput.ExternalServer]
        let projectCount: Int
        let crashReports: [SupportBundleInput.CrashReport]

        struct CloudUse: Encodable { let tokensThisMonth: Int; let monthlyLimit: Int? }
        /// What left this Mac: which kind of thing, to which host. Never the request itself.
        struct Egress: Encodable {
            let date: Date; let purpose: String; let host: String; let provider: String?
            let blocked: Bool; let count: Int
        }
    }

    public static let maxCrashReportCharacters = 200_000
    public static let maxCrashReports = 5

    public static func make(_ i: SupportBundleInput, now: Date = Date()) throws -> Data {
        let doc = Document(
            generatedAt: now,
            app: ["version": i.appVersion, "build": i.build],
            system: ["macOS": i.osVersion, "chip": i.chip, "memoryGB": String(i.memoryGB)],
            load: ["memory": "\(i.systemLoad.memory)", "thermal": "\(i.systemLoad.thermal)",
                   "lowPowerMode": String(i.systemLoad.lowPowerMode)],
            routingPolicy: i.routingPolicy,
            installedModels: i.installedModels,
            providers: i.providers,
            cloudUse: .init(tokensThisMonth: i.tokensThisMonth, monthlyLimit: i.monthlyTokenCap),
            requests: i.requests,
            egress: i.egress.map { .init(date: $0.date, purpose: $0.purpose.rawValue, host: $0.host,
                                          provider: $0.provider, blocked: $0.blocked, count: $0.count) },
            externalServers: i.externalServers,
            projectCount: i.projectCount,
            crashReports: i.crashReports.suffix(maxCrashReports).map {
                .init(file: $0.file, json: String($0.json.prefix(maxCrashReportCharacters))) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }
}
