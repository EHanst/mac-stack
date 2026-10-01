import Foundation

/// An error in the shape OpenAI clients expect: `{"error": {message, type, param, code}}`.
public struct OpenAIError: Error, Sendable, Equatable {
    public let status: Int
    public let message: String
    public let type: String
    public let param: String?
    public let code: String?

    public init(status: Int, message: String, type: String, param: String? = nil, code: String? = nil) {
        self.status = status
        self.message = message
        self.type = type
        self.param = param
        self.code = code
    }

    public static func invalidRequest(_ message: String, param: String? = nil, code: String? = nil) -> OpenAIError {
        OpenAIError(status: 400, message: message, type: "invalid_request_error", param: param, code: code)
    }
    public static let unauthorized = OpenAIError(
        status: 401, message: "Missing or invalid API key. Send the token you created in Kororo as 'Authorization: Bearer vc_…'.",
        type: "invalid_request_error", code: "invalid_api_key")
    public static func forbidden(_ message: String) -> OpenAIError {
        OpenAIError(status: 403, message: message, type: "permission_error", code: "insufficient_scope")
    }
    public static func notFound(_ message: String, code: String? = nil) -> OpenAIError {
        OpenAIError(status: 404, message: message, type: "invalid_request_error", code: code)
    }
    public static func server(_ message: String, status: Int = 500) -> OpenAIError {
        OpenAIError(status: status, message: message, type: "server_error")
    }

    private struct Envelope: Encodable {
        struct Body: Encodable { let message: String; let type: String; let param: String?; let code: String? }
        let error: Body
    }

    /// JSON body for the HTTP response.
    public var jsonBody: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Envelope(error: .init(message: message, type: type, param: param, code: code)))) ?? Data()
    }
}
