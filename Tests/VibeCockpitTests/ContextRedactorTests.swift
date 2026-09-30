import Testing
@testable import StackCore

@Suite("ContextRedactor")
struct ContextRedactorTests {
    @Test("known secret shapes are redacted", arguments: [
        ("AWS", "key = AKIAIOSFODNN7EXAMPLE"),
        ("GitHub token", "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
        ("API key", "OPENAI_KEY=sk-abcdefghijklmnopqrstuvwxyz123456"),
        ("private key", "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----"),
        ("bearer token", "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abcdefghij.klmnopqrst"),
        ("password", #"password = "hunter2hunter2""#),
    ])
    func redacts(kind: String, sample: String) {
        let out = ContextRedactor.redact(sample)
        #expect(out.count == 1)
        #expect(out.text.contains("[redacted"))
        #expect(!out.text.contains("AKIAIOSFODNN7EXAMPLE") && !out.text.contains("ghp_abc")
                && !out.text.contains("sk-abc") && !out.text.contains("MIIEow")
                && !out.text.contains("eyJhbGci") && !out.text.contains("hunter2"))
    }

    @Test("ordinary code is untouched")
    func untouched() {
        let code = "let key = cache.key(for: user)\nfunc tokenize(_ s: String) -> [Token] { [] }\nlet password = prompt()"
        let out = ContextRedactor.redact(code)
        #expect(out.text == code)
        #expect(out.count == 0)
    }

    @Test("redaction is idempotent")
    func idempotent() {
        let once = ContextRedactor.redact("k=AKIAIOSFODNN7EXAMPLE").text
        #expect(ContextRedactor.redact(once).text == once)
    }
}
