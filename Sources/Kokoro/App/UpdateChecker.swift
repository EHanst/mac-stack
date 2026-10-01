import Foundation
#if SWIFT_PACKAGE
import StackCore
#endif

public struct UpdateInfo: Equatable, Sendable {
    public let version: String
    /// The release page on github.com (never a direct download, never another host).
    public let url: URL
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(UpdateInfo)
}

public enum UpdateCheckError: LocalizedError, Equatable, Sendable {
    case badResponse
    case noReleases

    public var errorDescription: String? {
        switch self {
        case .badResponse: "GitHub's answer wasn't understood. Try again later."
        case .noReleases: "No release has been published yet."
        }
    }
}

/// Asks GitHub whether a newer release exists. Read-only: one GET, no identifiers, no installing.
/// The user downloads the DMG themselves from the release page.
public struct UpdateChecker: Sendable {
    public static let endpoint = URL(string: "https://api.github.com/repos/EHanst/mac-stack/releases/latest")!

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let fetch: Fetch
    private let gate: EgressGate?

    public init(gate: EgressGate? = nil,
                fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.gate = gate
        self.fetch = fetch
    }

    public func check(currentVersion: String) async throws -> UpdateCheckResult {
        if let gate { try await gate.authorize(.updateCheck, url: Self.endpoint) }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.badResponse }
        if http.statusCode == 404 { throw UpdateCheckError.noReleases }
        guard http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let page = URL(string: release.html_url), page.scheme == "https", page.host == "github.com"
        else { throw UpdateCheckError.badResponse }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard Self.isNewer(version, than: currentVersion) else { return .upToDate }
        return .available(UpdateInfo(version: version, url: page))
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
    }

    /// Dotted numbers compared part by part ("1.10.0" > "1.9.3"). Anything unparsable is "not newer".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".").map { Int($0) }
            return p.isEmpty || p.contains(nil) ? nil : p.map { $0! }
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
