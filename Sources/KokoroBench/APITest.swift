import Foundation
import StackCore
import StackHTTP

/// `--api-test`: the OpenAI-compatible server in front of the real model, driven over HTTP.
/// Checks that streamed text is sensible, that a client disconnect frees the GPU, and that a
/// request made while another is running waits its turn instead of failing.
func runAPITest(provider: LocalMLXProvider, port: Int = 11_599) async throws {
    print("[api test] StackAPIServer on 127.0.0.1:\(port) in front of the real model")
    let registry = ModelRegistry()
    await registry.register(provider)
    let service = InferenceService(registry: registry, policy: .localOnly)

    let store = FileClientStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-api-test-\(UUID().uuidString).json"))
    let clients = try ClientRegistry(store: store)
    let (_, token) = try await clients.create(name: "api-test")

    let server = StackAPIServer(inference: service, clients: clients, configuration: APIServerConfiguration(port: port))
    let serverTask = Task { try await server.run() }
    defer { serverTask.cancel() }

    let base = URL(string: "http://127.0.0.1:\(port)")!
    for _ in 0..<50 {
        if let (_, r) = try? await URLSession.shared.data(from: base.appendingPathComponent("healthz")),
           (r as? HTTPURLResponse)?.statusCode == 200 { break }
        try await Task.sleep(for: .milliseconds(100))
    }

    func request(_ path: String, body: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(body.utf8)
        return r
    }
    func chatBody(_ prompt: String, max: Int, stream: Bool) -> String {
        #"{"model":"auto","messages":[{"role":"user","content":"\#(prompt)"}],"max_tokens":\#(max),"temperature":0,"stream":\#(stream),"stream_options":{"include_usage":true}}"#
    }
    func content(_ line: String) -> String? {
        guard line.hasPrefix("data: "), line != "data: [DONE]",
              let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
              let delta = (obj["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    // 1. Streaming answer: print the text so it can be read, not just timed.
    do {
        let t0 = Date()
        var firstToken: Double?, text = "", chunks = 0, sawDone = false
        let (bytes, response) = try await URLSession.shared.bytes(for: request("v1/chat/completions", body: chatBody("What is the capital of France? Answer in one sentence.", max: 40, stream: true)))
        for try await line in bytes.lines {
            if line == "data: [DONE]" { sawDone = true }
            if let c = content(line), !c.isEmpty { chunks += 1; text += c; if firstToken == nil { firstToken = Date().timeIntervalSince(t0) } }
        }
        print("  1. streaming: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), first token \(fmt(firstToken ?? -1, 2)) s, \(chunks) chunks, [DONE] \(sawDone)")
        print("     text: \(text.replacingOccurrences(of: "\n", with: "⏎"))")
    }

    // 2. Non-streaming answer.
    do {
        let (data, response) = try await URLSession.shared.data(for: request("v1/chat/completions", body: chatBody("Name three colours, comma separated.", max: 24, stream: false)))
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        let usage = obj?["usage"] as? [String: Any]
        print("  2. non-streaming: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), usage \(usage ?? [:]), text: \(message ?? "nil")")
    }

    // 3. Disconnect mid-generation, then a new request: the GPU must be free again.
    do {
        let reader = Task { () -> Int in
            let (bytes, _) = try await URLSession.shared.bytes(for: request("v1/chat/completions", body: chatBody("Write a long story about a lighthouse.", max: 600, stream: true)))
            var n = 0
            for try await line in bytes.lines where content(line) != nil { n += 1; if n == 3 { break } }
            return n
        }
        let got = try await reader.value            // leaving scope closes the connection
        let t1 = Date()
        var first: Double?
        let (bytes, _) = try await URLSession.shared.bytes(for: request("v1/chat/completions", body: chatBody("Say hi.", max: 8, stream: true)))
        for try await line in bytes.lines where first == nil && (content(line)?.isEmpty == false) { first = Date().timeIntervalSince(t1) }
        print("  3. disconnect after \(got) chunks of a 600-token request; next request first token \(fmt(first ?? -1, 2)) s later (≈55 s if the GPU had not been freed)")
    }

    // 4. Two clients at once: both must succeed, one after the other.
    do {
        let t0 = Date()
        async let a: (Int, Double) = {
            let (_, r) = try await URLSession.shared.data(for: request("v1/chat/completions", body: chatBody("Count from 1 to 5.", max: 24, stream: false)))
            return ((r as? HTTPURLResponse)?.statusCode ?? 0, Date().timeIntervalSince(t0))
        }()
        async let b: (Int, Double) = {
            let (_, r) = try await URLSession.shared.data(for: request("v1/chat/completions", body: chatBody("Name three animals.", max: 24, stream: false)))
            return ((r as? HTTPURLResponse)?.statusCode ?? 0, Date().timeIntervalSince(t0))
        }()
        let (ra, rb) = try await (a, b)
        print("  4. two concurrent clients: HTTP \(ra.0)/\(rb.0), done at \(fmt(min(ra.1, rb.1), 1)) s and \(fmt(max(ra.1, rb.1), 1)) s")
    }
    print("")
}
