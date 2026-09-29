import Foundation
import MCP
#if SWIFT_PACKAGE
import StackCore
#endif

// MARK: - WebSession (injectable for testing)

public protocol WebSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: WebSession {}

// MARK: - Web Fetch

public struct WebFetchTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "web_fetch",
        description: "Fetch a web page and return its plain-text content. Use for reading documentation, release notes, or any public URL.",
        inputSchema: .object([
            "url": .object(["type": "string", "description": "The URL to fetch"]),
            "maxChars": .object(["type": "integer", "description": "Max characters to return (default 8000)"]),
        ])
    )

    private let session: any WebSession
    public init(session: any WebSession = URLSession.shared) { self.session = session }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let rawURL) = arguments["url"],
              let url = URL(string: rawURL),
              let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            throw AgentToolError.missingArgument("url")
        }
        let maxChars: Int
        if case .int(let n) = arguments["maxChars"] { maxChars = n } else { maxChars = 8_000 }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw WebResearchError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let text = contentType.contains("text/html") ? stripHTML(raw) : raw
        let result = text.count > maxChars ? String(text.prefix(maxChars)) + "\n[truncated]" : text
        return [.text(result)]
    }
}

// MARK: - Web Search

public struct WebSearchTool: AgentToolHandler {
    public let toolDefinition = Tool(
        name: "web_search",
        description: "Search the web using Brave Search and return ranked results with titles, URLs, and descriptions. Requires a Brave Search API key stored under provider ID 'brave-search'.",
        inputSchema: .object([
            "query": .object(["type": "string", "description": "Search query"]),
            "count": .object(["type": "integer", "description": "Number of results to return (default 5, max 10)"]),
        ])
    )

    private let credentials: CredentialStore
    private let session: any WebSession
    public init(credentials: CredentialStore, session: any WebSession = URLSession.shared) {
        self.credentials = credentials
        self.session = session
    }

    public func execute(arguments: [String: Value]) async throws -> [Tool.Content] {
        guard case .string(let query) = arguments["query"] else {
            throw AgentToolError.missingArgument("query")
        }
        let count: Int
        if case .int(let n) = arguments["count"] { count = min(n, 10) } else { count = 5 }

        let apiKey = try await credentials.token(for: "brave-search")

        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count)),
        ]
        guard let url = components.url else {
            throw WebResearchError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw WebResearchError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let webObj = json["web"] as? [String: Any],
              let results = webObj["results"] as? [[String: Any]] else {
            throw WebResearchError.malformedResponse
        }

        let formatted = results.enumerated().map { (i, result) -> String in
            let title = result["title"] as? String ?? "(no title)"
            let url = result["url"] as? String ?? ""
            let desc = result["description"] as? String ?? ""
            return "\(i + 1). \(title)\n   \(url)\n   \(desc)"
        }.joined(separator: "\n\n")

        return [.text(formatted.isEmpty ? "No results found." : formatted)]
    }
}

// MARK: - Errors

public enum WebResearchError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Could not construct search URL."
        case .httpError(let code): "HTTP error \(code)."
        case .malformedResponse: "Unexpected response format from search API."
        }
    }
}

// MARK: - HTML stripping

private func stripHTML(_ html: String) -> String {
    var result = html
    result = result.replacingOccurrences(
        of: #"<(script|style)[^>]*>[\s\S]*?</\1>"#,
        with: " ", options: .regularExpression
    )
    result = result.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    let entities: KeyValuePairs<String, String> = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">",
        "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]
    for (entity, char) in entities {
        result = result.replacingOccurrences(of: entity, with: char)
    }
    return result
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}
