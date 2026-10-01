import Testing
import Foundation
import StackCore
@testable import StackHTTP
@testable import KokoroCore

private func decode(_ json: String) throws -> OpenAIChatRequest {
    try JSONDecoder().decode(OpenAIChatRequest.self, from: Data(json.utf8))
}
private func generation(_ json: String) throws -> ChatGeneration { try decode(json).toGeneration() }
private func object(_ s: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}
/// Payload of every `data:` line in an SSE string (excluding [DONE]).
private func sseObjects(_ s: String) throws -> [[String: Any]] {
    try s.components(separatedBy: "\n\n").compactMap { block -> [String: Any]? in
        guard block.hasPrefix("data: "), !block.hasSuffix("[DONE]") else { return nil }
        return try object(String(block.dropFirst(6)))
    }
}

@Suite("OpenAI chat request → generation")
struct OpenAIChatRequestTests {

    @Test("a typical SDK request maps to messages and defaults")
    func basic() throws {
        let g = try generation(#"{"model":"local:Bonsai-27B","messages":[{"role":"system","content":"Be brief."},{"role":"user","content":"hi"}]}"#)
        #expect(g.messages.map(\.role) == [.system, .user])
        #expect(g.messages.map(\.content) == ["Be brief.", "hi"])
        #expect(g.requestedModel == "local:Bonsai-27B" && !g.stream && !g.hasTools)
        #expect(g.options.maxTokens == GenerationOptions.defaultMaxTokens)
        #expect(g.options.sampling == nil)                         // nothing set ⇒ the model card's defaults
    }

    @Test("content parts of type text are joined; the 'developer' role is a system message")
    func partsAndDeveloper() throws {
        let g = try generation(#"{"messages":[{"role":"developer","content":"rules"},{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}]}"#)
        #expect(g.messages.map(\.role) == [.system, .user])
        #expect(g.messages[1].content == "a\nb")
    }

    @Test("images and other content types are refused clearly")
    func images() {
        #expect(throws: OpenAIError.self) {
            _ = try generation(#"{"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"http://x"}}]}]}"#)
        }
    }

    @Test("invalid requests are 400s that name the offending field")
    func invalid() throws {
        func error(_ json: String) -> OpenAIError? { do { _ = try generation(json); return nil } catch { return error as? OpenAIError } }
        let empty = try #require(error(#"{"messages":[]}"#))
        #expect(empty.status == 400 && empty.param == "messages")
        #expect(error(#"{}"#)?.param == "messages")
        #expect(error(#"{"messages":[{"role":"user","content":"x"}],"n":2}"#)?.param == "n")
        #expect(error(#"{"messages":[{"role":"wizard","content":"x"}]}"#)?.param == "messages[0].role")
        #expect(error(#"{"messages":[{"role":"system","content":"only system"}]}"#)?.param == "messages")
        #expect(error(#"{"messages":[{"role":"user","content":"x"}],"max_tokens":0}"#)?.param == "max_tokens")
    }

    @Test("max_completion_tokens wins over max_tokens and both are capped")
    func maxTokens() throws {
        #expect(try generation(#"{"messages":[{"role":"user","content":"x"}],"max_tokens":100}"#).options.maxTokens == 100)
        #expect(try generation(#"{"messages":[{"role":"user","content":"x"}],"max_tokens":100,"max_completion_tokens":50}"#).options.maxTokens == 50)
        #expect(try generation(#"{"messages":[{"role":"user","content":"x"}],"max_tokens":9999999}"#).options.maxTokens == OpenAIChatRequest.maxAllowedTokens)
    }

    @Test("sampling fields override the card's defaults one by one; temperature 0 is greedy")
    func sampling() throws {
        let m = #"[{"role":"user","content":"x"}]"#
        let card = SamplingParameters.bonsaiInstruct
        #expect(try generation(#"{"messages":\#(m),"temperature":0}"#).options.sampling == .greedy)
        let warm = try #require(try generation(#"{"messages":\#(m),"temperature":1.0}"#).options.sampling)
        #expect(warm.temperature == 1.0 && warm.topK == card.topK && warm.topP == card.topP && warm.presencePenalty == card.presencePenalty)
        let custom = try #require(try generation(#"{"messages":\#(m),"top_p":0.5,"top_k":5,"presence_penalty":0}"#).options.sampling)
        #expect(custom.temperature == card.temperature && custom.topP == 0.5 && custom.topK == 5 && custom.presencePenalty == 0)
    }

    @Test("stop accepts a string or a list, keeps at most four, drops empties")
    func stop() throws {
        let m = #"[{"role":"user","content":"x"}]"#
        #expect(try generation(#"{"messages":\#(m),"stop":"END"}"#).options.stopSequences == ["END"])
        #expect(try generation(#"{"messages":\#(m),"stop":["a","","b","c","d","e"]}"#).options.stopSequences == ["a", "b", "c", "d"])
    }

    @Test("stream flags and tool presence are carried through")
    func flags() throws {
        let g = try generation(#"{"messages":[{"role":"user","content":"x"}],"stream":true,"stream_options":{"include_usage":true},"tools":[{"type":"function","function":{"name":"f"}}]}"#)
        #expect(g.stream && g.includeUsage && g.hasTools)
        #expect(!(try generation(#"{"messages":[{"role":"user","content":"x"}],"tools":[]}"#).hasTools))
    }

    @Test("tool-result messages keep their call id")
    func toolMessages() throws {
        let g = try generation(#"{"messages":[{"role":"user","content":"q"},{"role":"assistant","content":null},{"role":"tool","tool_call_id":"call_1","content":"42"}]}"#)
        #expect(g.messages.last?.role == .tool && g.messages.last?.toolCallID == "call_1" && g.messages[1].content == "")
    }
}

@Suite("OpenAI response encoding")
struct OpenAIResponseTests {

    private let builder = ChatCompletionBuilder(model: "local:Bonsai-27B", id: "chatcmpl-test", created: Date(timeIntervalSince1970: 1_700_000_000))

    @Test("a full response has the fields SDKs read")
    func fullResponse() throws {
        let o = try object(builder.response(text: "Hello!", finish: .stop, usage: GenerationUsage(promptTokens: 12, completionTokens: 3)))
        #expect(o["id"] as? String == "chatcmpl-test" && o["object"] as? String == "chat.completion")
        #expect(o["created"] as? Int == 1_700_000_000 && o["model"] as? String == "local:Bonsai-27B")
        let choice = try #require((o["choices"] as? [[String: Any]])?.first)
        #expect(choice["index"] as? Int == 0 && choice["finish_reason"] as? String == "stop")
        let message = try #require(choice["message"] as? [String: Any])
        #expect(message["role"] as? String == "assistant" && message["content"] as? String == "Hello!")
        let usage = try #require(o["usage"] as? [String: Int])
        #expect(usage == ["prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15])
    }

    @Test("finish reasons map to OpenAI's names")
    func finishReasons() {
        #expect(OpenAIFinish.string(.stop) == "stop" && OpenAIFinish.string(.length) == "length")
        #expect(OpenAIFinish.string(.toolUse) == "tool_calls" && OpenAIFinish.string(.error) == "stop")
    }

    @Test("a stream is: role chunk, content deltas, finish chunk, [DONE]")
    func stream() throws {
        var out = builder.streamStart()
        out += builder.streamDelta("Hel") + builder.streamDelta("lo")
        out += builder.streamEnd(finish: .length, usage: nil, includeUsage: false)
        #expect(out.hasSuffix("data: [DONE]\n\n"))
        let chunks = try sseObjects(out)
        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { $0["object"] as? String == "chat.completion.chunk" && $0["id"] as? String == "chatcmpl-test" })
        func delta(_ c: [String: Any]) -> [String: Any]? { ((c["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any] }
        #expect(delta(chunks[0])?["role"] as? String == "assistant")
        #expect(delta(chunks[1])?["content"] as? String == "Hel" && delta(chunks[2])?["content"] as? String == "lo")
        #expect(((chunks[3]["choices"] as? [[String: Any]])?.first)?["finish_reason"] as? String == "length")
        #expect(chunks[1]["usage"] == nil)
        // The role is only in the first chunk.
        #expect(delta(chunks[1])?["role"] == nil)
    }

    @Test("usage chunk appears only when the client asked for it, with empty choices")
    func streamUsage() throws {
        let usage = GenerationUsage(promptTokens: 5, completionTokens: 2)
        let without = try sseObjects(builder.streamEnd(finish: .stop, usage: usage, includeUsage: false))
        #expect(without.count == 1)
        let with = try sseObjects(builder.streamEnd(finish: .stop, usage: usage, includeUsage: true))
        #expect(with.count == 2)
        #expect((with[1]["choices"] as? [Any])?.isEmpty == true)
        #expect((with[1]["usage"] as? [String: Int])?["total_tokens"] == 7)
    }

    @Test("text with quotes, newlines, unicode and slashes stays valid JSON")
    func escaping() throws {
        let nasty = "He said \"hi\"\nline2 \\ back/slash 你好 🙂"
        let chunk = try sseObjects(builder.streamDelta(nasty))[0]
        let content = (((chunk["choices"] as? [[String: Any]])?.first?["delta"]) as? [String: Any])?["content"] as? String
        #expect(content == nasty)
        let full = try object(builder.response(text: nasty, finish: .stop, usage: GenerationUsage(promptTokens: 1, completionTokens: 1)))
        #expect((((full["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any])?["content"] as? String == nasty)
    }

    @Test("errors come in OpenAI's envelope with the right status")
    func errors() throws {
        let e = try object(String(data: OpenAIError.unauthorized.jsonBody, encoding: .utf8)!)
        let body = try #require(e["error"] as? [String: Any])
        #expect(OpenAIError.unauthorized.status == 401 && body["code"] as? String == "invalid_api_key")
        #expect((body["message"] as? String)?.contains("Bearer vc_") == true)
        #expect(OpenAIError.forbidden("x").status == 403 && OpenAIError.notFound("x").status == 404)
        #expect(OpenAIError.invalidRequest("bad", param: "n").status == 400)
    }

    @Test("an error after streaming began is delivered in-band and still ends with [DONE]")
    func midStreamError() {
        let s = builder.streamError(.server("model crashed"))
        #expect(s.contains("model crashed") && s.hasSuffix("data: [DONE]\n\n"))
    }
}

@Suite("OpenAI models and embeddings")
struct OpenAIModelsEmbeddingsTests {

    @Test("model list has the OpenAI shape")
    func models() throws {
        let o = try object(OpenAIModelList.json([.init(id: "local:Bonsai-27B", ownedBy: "this-mac"), .init(id: "gpt-4o", ownedBy: "openai")],
                                                created: Date(timeIntervalSince1970: 5)))
        #expect(o["object"] as? String == "list")
        let data = try #require(o["data"] as? [[String: Any]])
        #expect(data.map { $0["id"] as? String } == ["local:Bonsai-27B", "gpt-4o"])
        #expect(data.allSatisfy { $0["object"] as? String == "model" && $0["created"] as? Int == 5 })
    }

    @Test("embedding input may be a string or a list; empty, oversized and non-float formats are refused")
    func embeddingInput() throws {
        func req(_ json: String) throws -> OpenAIEmbeddingsRequest { try JSONDecoder().decode(OpenAIEmbeddingsRequest.self, from: Data(json.utf8)) }
        #expect(try req(#"{"input":"hello"}"#).texts() == ["hello"])
        #expect(try req(#"{"input":["a","b"],"model":"m"}"#).texts() == ["a", "b"])
        #expect(throws: OpenAIError.self) { _ = try req(#"{"input":[]}"#).texts() }
        #expect(throws: OpenAIError.self) { _ = try req(#"{}"#).texts() }
        #expect(throws: OpenAIError.self) { _ = try req(#"{"input":"x","encoding_format":"base64"}"#).texts() }
        let many = "[" + (0...OpenAIEmbeddingsRequest.maxInputs).map { "\"t\($0)\"" }.joined(separator: ",") + "]"
        #expect(throws: OpenAIError.self) { _ = try req(#"{"input":\#(many)}"#).texts() }
        #expect(throws: (any Error).self) { _ = try req(#"{"input":[[1,2,3]]}"#) }      // token arrays
    }

    @Test("embedding response lists vectors with their index")
    func embeddingResponse() throws {
        let o = try object(OpenAIEmbeddingsResponse.json(vectors: [[0.5, -1], [2, 3]], model: "bge", promptTokens: 9))
        let data = try #require(o["data"] as? [[String: Any]])
        #expect(data.count == 2 && data[1]["index"] as? Int == 1 && data[0]["embedding"] as? [Double] == [0.5, -1])
        #expect((o["usage"] as? [String: Int])?["prompt_tokens"] == 9 && o["model"] as? String == "bge")
    }
}
