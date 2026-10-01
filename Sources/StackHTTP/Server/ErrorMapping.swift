import Foundation
import HTTPTypes
import Hummingbird
#if SWIFT_PACKAGE
import StackCore
#endif

extension OpenAIError {

    /// Turn anything thrown while serving a request into an error OpenAI clients understand.
    /// Internal details are logged, not sent.
    public static func from(_ error: Error) -> OpenAIError {
        switch error {
        case let e as OpenAIError:
            return e
        case let e as QueryError:
            switch e {
            case .invalid(let param, let message):
                return .invalidRequest(message, param: param)
            case .unknownModel(let id):
                return .notFound("The model '\(id)' does not exist. See GET /v1/models.", code: "model_not_found")
            case .blockedByPrivacy:
                return OpenAIError(status: 403, message: e.localizedDescription, type: "permission_error", code: "blocked_by_privacy_setting")
            case .budgetExhausted:
                return OpenAIError(status: 429, message: e.localizedDescription, type: "insufficient_quota", code: "monthly_limit_reached")
            case .noModelAvailable:
                return OpenAIError(status: 503, message: e.localizedDescription, type: "server_error", code: "no_model_available")
            case .contextTooLarge:
                return .invalidRequest(e.localizedDescription, param: "messages", code: "context_length_exceeded")
            case .upstream(let message):
                return OpenAIError(status: 502, message: message, type: "server_error", code: "upstream_error")
            case .cancelled, .internal:
                return .server(e.localizedDescription)
            }
        case let e as InferenceError:
            switch e {
            case .unknownModel(let id):
                return .notFound("The model '\(id)' does not exist. See GET /v1/models.", code: "model_not_found")
            case .notAllowedByPolicy:
                return OpenAIError(status: 403, message: e.localizedDescription, type: "permission_error", code: "blocked_by_privacy_setting")
            case .noProvider:
                return OpenAIError(status: 503, message: e.localizedDescription, type: "server_error", code: "no_model_available")
            }
        case let e as EgressError:
            switch e {
            case .blockedByPrivacy:
                return OpenAIError(status: 403, message: e.localizedDescription, type: "permission_error", code: "blocked_by_privacy_setting")
            case .budgetExhausted:
                return OpenAIError(status: 429, message: e.localizedDescription, type: "insufficient_quota", code: "monthly_limit_reached")
            }
        case let e as LocalModelError:
            if case .contextTooLarge = e {
                return .invalidRequest(e.localizedDescription, param: "messages", code: "context_length_exceeded")
            }
            return .server(e.localizedDescription)
        case let e as ProviderError:
            if case .httpError(let code) = e {
                return OpenAIError(status: 502, message: "The cloud provider answered with HTTP \(code).", type: "server_error", code: "upstream_error")
            }
            return OpenAIError(status: 502, message: e.localizedDescription, type: "server_error", code: "upstream_error")
        case is DecodingError:
            return .invalidRequest("The request body is not valid JSON for this endpoint.", code: "invalid_json")
        case let e as HTTPError:
            let status = Int(e.status.code)
            if status == 404 { return .notFound("Unknown endpoint.", code: "unknown_endpoint") }
            return OpenAIError(status: status, message: status == 413 ? "The request body is too large." : e.status.reasonPhrase,
                               type: "invalid_request_error", code: status == 413 ? "request_too_large" : nil)
        default:
            return .server("Something went wrong inside Kororo while handling this request.")
        }
    }

    func response(extra: HTTPFields = [:]) -> Response {
        var headers = extra
        headers[.contentType] = "application/json"
        return Response(status: HTTPResponse.Status(code: status), headers: headers,
                        body: .init(byteBuffer: .init(data: jsonBody)))
    }
}
