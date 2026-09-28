import Testing
import Foundation
@testable import VibeCockpitCore

// MARK: - Mock web session

private struct MockWebSession: WebSession {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

private func makeHTTPResponse(url: URL, status: Int, contentType: String) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": contentType])!
}

// MARK: - WebFetchTool

@Suite("WebFetchTool", .serialized)
struct WebFetchToolTests {

    @Test("throws missingArgument when url is absent")
    func missingURL() async {
        let tool = WebFetchTool()
        await #expect(throws: AgentToolError.self) {
            _ = try await tool.execute(arguments: [:])
        }
    }

    @Test("throws missingArgument for malformed URL string")
    func malformedURL() async {
        let tool = WebFetchTool()
        await #expect(throws: AgentToolError.self) {
            _ = try await tool.execute(arguments: ["url": .string("not a url %%")])
        }
    }

    @Test("returns body as-is for text/plain response")
    func plainTextResponse() async throws {
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "text/plain")
            return (Data("Hello, world!".utf8), resp)
        }
        let tool = WebFetchTool(session: session)
        let result = try await tool.execute(arguments: ["url": .string("https://example.com")])
        let text = result.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }
            .joined()
        #expect(text.contains("Hello, world!"))
    }

    @Test("strips HTML tags for text/html response")
    func htmlStripping() async throws {
        let html = "<html><head><style>body{color:red}</style></head><body><h1>Title</h1><p>Body text.</p></body></html>"
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "text/html; charset=utf-8")
            return (Data(html.utf8), resp)
        }
        let tool = WebFetchTool(session: session)
        let result = try await tool.execute(arguments: ["url": .string("https://example.com")])
        let text = result.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }
            .joined()
        #expect(!text.contains("<h1>"))
        #expect(!text.contains("<p>"))
        #expect(text.contains("Title"))
        #expect(text.contains("Body text."))
    }

    @Test("strips script blocks before tag removal")
    func scriptBlocksStripped() async throws {
        let html = "<html><body><script>var x = 1;</script><p>Content</p></body></html>"
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "text/html")
            return (Data(html.utf8), resp)
        }
        let tool = WebFetchTool(session: session)
        let result = try await tool.execute(arguments: ["url": .string("https://example.com")])
        let text = result.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }
            .joined()
        #expect(!text.contains("var x = 1"))
        #expect(text.contains("Content"))
    }

    @Test("decodes common HTML entities")
    func entityDecoding() async throws {
        let html = "<p>a &amp; b &lt;c&gt; &quot;d&quot; &nbsp;e</p>"
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "text/html")
            return (Data(html.utf8), resp)
        }
        let tool = WebFetchTool(session: session)
        let result = try await tool.execute(arguments: ["url": .string("https://example.com")])
        let text = result.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }
            .joined()
        #expect(text.contains("a & b"))
        #expect(text.contains("<c>"))
        #expect(text.contains("\"d\""))
    }

    @Test("truncates response and appends [truncated] marker")
    func truncation() async throws {
        let longBody = String(repeating: "x", count: 500)
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "text/plain")
            return (Data(longBody.utf8), resp)
        }
        let tool = WebFetchTool(session: session)
        let result = try await tool.execute(arguments: [
            "url": .string("https://example.com"),
            "maxChars": .int(100),
        ])
        let text = result.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }
            .joined()
        #expect(text.hasSuffix("[truncated]"))
        #expect(text.count < 200)
    }

    @Test("does not truncate when response is within maxChars")
    func noTruncationWhenShort() async throws {
        let body = "Short response."
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "text/plain")
            return (Data(body.utf8), resp)
        }
        let tool = WebFetchTool(session: session)
        let result = try await tool.execute(arguments: [
            "url": .string("https://example.com"),
            "maxChars": .int(8_000),
        ])
        let text = result.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }
            .joined()
        #expect(!text.contains("[truncated]"))
        #expect(text.contains("Short response."))
    }

    @Test("throws WebResearchError.httpError on 404")
    func httpError404() async {
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 404, contentType: "text/plain")
            return (Data(), resp)
        }
        let tool = WebFetchTool(session: session)
        await #expect(throws: WebResearchError.self) {
            _ = try await tool.execute(arguments: ["url": .string("https://example.com")])
        }
    }

    @Test("throws WebResearchError.httpError on 500")
    func httpError500() async {
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 500, contentType: "text/plain")
            return (Data(), resp)
        }
        let tool = WebFetchTool(session: session)
        await #expect(throws: WebResearchError.self) {
            _ = try await tool.execute(arguments: ["url": .string("https://example.com")])
        }
    }

    @Test("sends User-Agent header")
    func sendsUserAgent() async throws {
        nonisolated(unsafe) var capturedHeaders: [String: String] = [:]
        let session = MockWebSession { req in
            capturedHeaders = req.allHTTPHeaderFields ?? [:]
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "text/plain")
            return (Data("ok".utf8), resp)
        }
        let tool = WebFetchTool(session: session)
        _ = try await tool.execute(arguments: ["url": .string("https://example.com")])
        #expect(capturedHeaders["User-Agent"]?.contains("Mozilla") == true)
    }
}

// MARK: - WebSearchTool

@Suite("WebSearchTool", .serialized)
struct WebSearchToolTests {

    @Test("throws missingArgument when query is absent")
    func missingQuery() async {
        let session = MockWebSession { _ in throw URLError(.unknown) }
        let tool = WebSearchTool(credentials: CredentialStore(service: "com.vibecockpit.test"), session: session)
        await #expect(throws: AgentToolError.self) {
            _ = try await tool.execute(arguments: [:])
        }
    }

    @Test("throws CredentialError.notFound when API key is not stored")
    func missingAPIKey() async {
        let session = MockWebSession { _ in throw URLError(.unknown) }
        let tool = WebSearchTool(credentials: CredentialStore(service: "com.vibecockpit.test"), session: session)
        await #expect(throws: CredentialStore.CredentialError.self) {
            _ = try await tool.execute(arguments: ["query": .string("swift actors")])
        }
    }

    @Test("parses Brave Search JSON and returns formatted results")
    func parsesResults() async throws {
        let json = """
        {"web":{"results":[
            {"title":"Swift Docs","url":"https://swift.org","description":"The Swift programming language."},
            {"title":"Swift Forums","url":"https://forums.swift.org","description":"Community discussions."}
        ]}}
        """
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "application/json")
            return (Data(json.utf8), resp)
        }
        let creds = CredentialStore(service: "com.vibecockpit.test")
        try? await creds.delete(for: "brave-search")
        try await creds.store(token: "test-key-parse", for: "brave-search")
        let tool = WebSearchTool(credentials: creds, session: session)
        let result = try await tool.execute(arguments: ["query": .string("swift")])
        try? await creds.delete(for: "brave-search")
        let text = result.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }
            .joined()
        #expect(text.contains("1. Swift Docs"))
        #expect(text.contains("https://swift.org"))
        #expect(text.contains("The Swift programming language."))
        #expect(text.contains("2. Swift Forums"))
    }

    @Test("returns 'No results found.' for empty results array")
    func emptyResults() async throws {
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "application/json")
            return (Data(#"{"web":{"results":[]}}"#.utf8), resp)
        }
        let creds = CredentialStore(service: "com.vibecockpit.test")
        try? await creds.delete(for: "brave-search")
        try await creds.store(token: "test-key-empty", for: "brave-search")
        let tool = WebSearchTool(credentials: creds, session: session)
        let result = try await tool.execute(arguments: ["query": .string("xyzzy")])
        try? await creds.delete(for: "brave-search")
        let text = result.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }
            .joined()
        #expect(text == "No results found.")
    }

    @Test("caps count query parameter at 10")
    func countCappedAtTen() async throws {
        nonisolated(unsafe) var capturedURL: URL?
        let session = MockWebSession { req in
            capturedURL = req.url
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "application/json")
            return (Data(#"{"web":{"results":[]}}"#.utf8), resp)
        }
        let creds = CredentialStore(service: "com.vibecockpit.test")
        try? await creds.delete(for: "brave-search")
        try await creds.store(token: "test-key-cap", for: "brave-search")
        let tool = WebSearchTool(credentials: creds, session: session)
        _ = try? await tool.execute(arguments: [
            "query": .string("test"),
            "count": .int(999),
        ])
        try? await creds.delete(for: "brave-search")
        #expect(capturedURL?.query?.contains("count=10") == true)
    }

    @Test("sends API key in X-Subscription-Token header")
    func sendsAPIKeyHeader() async throws {
        nonisolated(unsafe) var capturedHeaders: [String: String] = [:]
        let session = MockWebSession { req in
            capturedHeaders = req.allHTTPHeaderFields ?? [:]
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "application/json")
            return (Data(#"{"web":{"results":[]}}"#.utf8), resp)
        }
        let creds = CredentialStore(service: "com.vibecockpit.test")
        try? await creds.delete(for: "brave-search")
        try await creds.store(token: "my-brave-key", for: "brave-search")
        let tool = WebSearchTool(credentials: creds, session: session)
        _ = try? await tool.execute(arguments: ["query": .string("test")])
        try? await creds.delete(for: "brave-search")
        #expect(capturedHeaders["X-Subscription-Token"] == "my-brave-key")
    }

    @Test("throws WebResearchError.malformedResponse for unexpected JSON shape")
    func malformedJSON() async throws {
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "application/json")
            return (Data(#"{"unexpected":true}"#.utf8), resp)
        }
        let creds = CredentialStore(service: "com.vibecockpit.test")
        try? await creds.delete(for: "brave-search")
        try await creds.store(token: "test-key-malformed", for: "brave-search")
        let tool = WebSearchTool(credentials: creds, session: session)
        await #expect(throws: WebResearchError.self) {
            _ = try await tool.execute(arguments: ["query": .string("swift")])
        }
        try? await creds.delete(for: "brave-search")
    }

    @Test("throws WebResearchError.httpError on non-2xx response")
    func httpError() async throws {
        let session = MockWebSession { req in
            let resp = makeHTTPResponse(url: req.url!, status: 403, contentType: "application/json")
            return (Data(), resp)
        }
        let creds = CredentialStore(service: "com.vibecockpit.test")
        try? await creds.delete(for: "brave-search")
        try await creds.store(token: "bad-key", for: "brave-search")
        let tool = WebSearchTool(credentials: creds, session: session)
        await #expect(throws: WebResearchError.self) {
            _ = try await tool.execute(arguments: ["query": .string("swift")])
        }
        try? await creds.delete(for: "brave-search")
    }

    @Test("encodes query string correctly in URL")
    func queryEncoding() async throws {
        nonisolated(unsafe) var capturedURL: URL?
        let session = MockWebSession { req in
            capturedURL = req.url
            let resp = makeHTTPResponse(url: req.url!, status: 200, contentType: "application/json")
            return (Data(#"{"web":{"results":[]}}"#.utf8), resp)
        }
        let creds = CredentialStore(service: "com.vibecockpit.test")
        try? await creds.delete(for: "brave-search")
        try await creds.store(token: "test-key-enc", for: "brave-search")
        let tool = WebSearchTool(credentials: creds, session: session)
        _ = try? await tool.execute(arguments: ["query": .string("swift async await")])
        try? await creds.delete(for: "brave-search")
        let query = capturedURL?.query ?? ""
        #expect(query.contains("q=swift"))
    }
}
