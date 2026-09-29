import Foundation
import MCP
import os
#if SWIFT_PACKAGE
import StackCore
#endif

/// MCP over Streamable HTTP: one session (its own transport and server) per initialised client.
/// The HTTP layer authenticates the request and passes who is calling; this keeps sessions
/// separate, so one app can't use another app's session id.
public actor MCPHTTPSessions {

    private struct Session {
        let transport: StatefulHTTPServerTransport
        let server: Server
        let owner: UUID
        let scopes: ScopeBox
        var lastUsed: Date
    }

    private let host: MCPToolHost
    private var sessions: [String: Session] = [:]
    private let maxSessions: Int
    private let log = Logger(subsystem: "com.vibecockpit", category: "MCPHTTP")

    public init(host: MCPToolHost, maxSessions: Int = 32) {
        self.host = host
        self.maxSessions = maxSessions
    }

    public var sessionCount: Int { sessions.count }

    /// `clientID`/`scopes` come from the bearer token the HTTP layer already verified.
    public func handle(_ request: HTTPRequest, clientID: UUID, clientName: String, scopes: Set<ClientScope>) async -> HTTPResponse {
        if let id = request.header(HTTPHeaderName.sessionID) {
            guard var session = sessions[id], session.owner == clientID else {
                return .error(statusCode: 404, .invalidRequest("Not Found: unknown session"))
            }
            session.scopes.scopes = scopes          // permission changes apply to running sessions
            session.scopes.identity = ClientIdentity(key: "client:\(clientID.uuidString)", name: clientName)
            session.lastUsed = Date()
            sessions[id] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" { await close(id) }
            return response
        }

        // No session yet: only an initialize POST may create one.
        guard request.method.uppercased() == "POST" else {
            return .error(statusCode: 400, .invalidRequest("Bad Request: missing MCP-Session-Id header"))
        }
        await evictIfFull()
        let box = ScopeBox(scopes, identity: ClientIdentity(key: "client:\(clientID.uuidString)", name: clientName))
        // Host/Origin are already checked by the server's own loopback guard (which also honours the
        // user's allowed origins), so the SDK's origin validator is left out to avoid two rulebooks.
        let transport = StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ]))
        let server = await host.makeServer(scopes: box)
        do { try await server.start(transport: transport) }
        catch {
            log.error("MCP session start failed: \(error.localizedDescription, privacy: .public)")
            return .error(statusCode: 500, .internalError("Couldn't start the session"))
        }
        let response = await transport.handleRequest(request)
        if let id = response.headers[HTTPHeaderName.sessionID] {
            sessions[id] = Session(transport: transport, server: server, owner: clientID, scopes: box, lastUsed: Date())
        } else {
            await server.stop()                     // not a valid initialize: nothing to keep
        }
        return response
    }

    public func closeAll() async {
        for id in Array(sessions.keys) { await close(id) }
    }

    private func close(_ id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.server.stop()
    }

    private func evictIfFull() async {
        guard sessions.count >= maxSessions,
              let oldest = sessions.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { return }
        await close(oldest)
    }
}
