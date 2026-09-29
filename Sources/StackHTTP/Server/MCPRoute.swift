import Foundation
import HTTPTypes
import Hummingbird
import MCP
import NIOCore
#if SWIFT_PACKAGE
import StackCore
import StackMCP
#endif

extension StackAPIServer {

    /// `/mcp`: the Streamable HTTP MCP endpoint, behind the same bearer tokens as the REST API.
    /// A client sees only the tools its permissions allow.
    func mcp(_ request: Request, context: APIRequestContext) async throws -> Response {
        guard let sessions = mcpSessions else {
            throw OpenAIError.notFound("MCP over HTTP isn't enabled.", code: "unknown_endpoint")
        }
        guard let client = context.client else { throw OpenAIError.unauthorized }

        var headers: [String: String] = [:]
        for field in request.headers { headers[field.name.rawName] = field.value }
        if let host = request.head.authority { headers["Host"] = host }
        let body = try await request.body.collect(upTo: configuration.maxBodyBytes)
        let sdkRequest = MCP.HTTPRequest(
            method: request.method.rawValue, headers: headers,
            body: body.readableBytes > 0 ? Data(body.readableBytesView) : nil, path: request.uri.path)

        let result = await sessions.handle(sdkRequest, clientID: client.id, scopes: client.scopes)
        return Self.response(from: result)
    }

    private static func response(from result: MCP.HTTPResponse) -> Response {
        var fields = HTTPFields()
        for (name, value) in result.headers {
            if let n = HTTPField.Name(name) { fields[n] = value }
        }
        let status = HTTPResponse.Status(code: result.statusCode)
        switch result {
        case .stream(let stream, _):
            return Response(status: status, headers: fields, body: .init { writer in
                for try await chunk in stream { try await writer.write(ByteBuffer(data: chunk)) }
                try await writer.finish(nil)
            })
        default:
            let data = result.bodyData
            return Response(status: status, headers: fields,
                            body: data.map { .init(byteBuffer: ByteBuffer(data: $0)) } ?? .init())
        }
    }
}
