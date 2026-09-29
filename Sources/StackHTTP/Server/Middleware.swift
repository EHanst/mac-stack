import Foundation
import HTTPTypes
import Hummingbird
#if SWIFT_PACKAGE
import StackCore
#endif

/// Per-request state: who is calling.
struct APIRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    var client: APIClient?
    init(source: Source) {
        self.coreContext = .init(source: source)
    }
}

/// Turns every thrown error into an OpenAI-shaped response and logs the unexpected ones.
struct ErrorMiddleware: RouterMiddleware {
    func handle(_ request: Request, context: APIRequestContext,
                next: (Request, APIRequestContext) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            let mapped = OpenAIError.from(error)
            if mapped.status >= 500 { context.logger.error("API error: \(error)") }
            return mapped.response()
        }
    }
}

/// Stops browsers (and DNS-rebinding pages) from talking to the local server.
///
/// - `Host` must name this machine (`127.0.0.1`, `localhost`, `[::1]`): a page on
///   `evil.example` whose DNS is rebound to 127.0.0.1 still sends `Host: evil.example`.
/// - A request carrying an `Origin` header came from a web page; only listed origins are served,
///   and no CORS headers are ever added, so pages can't read responses either way.
struct LoopbackGuard: RouterMiddleware {
    let allowedOrigins: Set<String>

    static func isLoopbackHost(_ hostHeader: String) -> Bool {
        var host = hostHeader.lowercased()
        if host.hasPrefix("[") {                       // [::1]:port
            guard let end = host.firstIndex(of: "]") else { return false }
            host = String(host[host.startIndex...end])
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[host.startIndex..<colon])
        }
        return host == "127.0.0.1" || host == "localhost" || host == "[::1]"
    }

    func handle(_ request: Request, context: APIRequestContext,
                next: (Request, APIRequestContext) async throws -> Response) async throws -> Response {
        guard let host = request.head.authority, Self.isLoopbackHost(host) else {
            return OpenAIError(status: 421, message: "This server only answers requests addressed to localhost.",
                               type: "invalid_request_error", code: "invalid_host").response()
        }
        if let origin = request.headers[HTTPField.Name("Origin")!], !allowedOrigins.contains(origin) {
            return OpenAIError(status: 403, message: "Requests from web pages are not allowed.",
                               type: "permission_error", code: "origin_not_allowed").response()
        }
        if request.method == .options {
            return OpenAIError(status: 403, message: "Cross-origin requests are not allowed.",
                               type: "permission_error", code: "origin_not_allowed").response()
        }
        return try await next(request, context)
    }
}

/// Requires `Authorization: Bearer vc_…` for everything except `/healthz`.
struct AuthMiddleware: RouterMiddleware {
    let clients: ClientRegistry

    func handle(_ request: Request, context: APIRequestContext,
                next: (Request, APIRequestContext) async throws -> Response) async throws -> Response {
        if request.uri.path == "/healthz" { return try await next(request, context) }
        guard let header = request.headers[.authorization], header.lowercased().hasPrefix("bearer ") else {
            return OpenAIError.unauthorized.response(extra: [.wwwAuthenticate: "Bearer"])
        }
        let token = header.dropFirst(7).trimmingCharacters(in: .whitespaces)
        guard let client = await clients.authenticate(token: token) else {
            return OpenAIError.unauthorized.response(extra: [.wwwAuthenticate: "Bearer"])
        }
        var context = context
        context.client = client
        return try await next(request, context)
    }
}

extension APIRequestContext {
    /// The calling client, or 401. Handlers call this and then check the scope they need.
    func require(_ scope: ClientScope) throws -> APIClient {
        guard let client else { throw OpenAIError.unauthorized }
        guard client.allows(scope) else {
            throw OpenAIError.forbidden("This key isn't allowed to \(scope.title.lowercased()). Change its permissions in VibeCockpit.")
        }
        return client
    }
}
