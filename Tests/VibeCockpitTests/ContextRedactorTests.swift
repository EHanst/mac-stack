import Testing
import Foundation
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

    @Test("common config shapes are redacted", arguments: [
        "DB_PASSWORD=hunter2hunter2",
        #"{"password": "hunter2hunter2"}"#,
        "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "STRIPE_SECRET_KEY=sk_live_abcdefghijklmnopqrstuvwx",
        #"let secretKey = "hunter2hunter2""#,
        "SECRET_KEY=hunter2hunter2",
        "authorization: bearer abcdefghijklmnopqrstuvwxyz0123",
        "github_pat_11ABCDEFG0abcdefghijklmnop_qrstuvwxyz",
        "SLACK=xoxb-1234567890-abcdefghij",
        "creds: ASIAIOSFODNN7EXAMPLE",
        #"password = "correct horse battery staple""#,
        "GOOGLE=AIzaSyA-abcdefghijklmnopqrstuvwxyz012345",
    ])
    func moreShapes(sample: String) {
        let out = ContextRedactor.redact(sample)
        #expect(out.count >= 1, "not redacted: \(sample)")
        #expect(out.text.contains("[redacted"))
    }

    @Test("identifiers that merely contain a keyword are left alone")
    func noFalsePositives() {
        let code = """
        let tokenizer = Tokenizer.shared
        var token: String
        let secretary = Person(name: "Alex Doe")
        cache.key(for: user)
        let passwordField = makeField()
        """
        #expect(ContextRedactor.redact(code).count == 0)
    }

    @Test("a private key with no END line is still redacted")
    func unterminatedKey() {
        let out = ContextRedactor.redact("-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\nabcdefghijklmnopqrstuv")
        #expect(out.count == 1 && !out.text.contains("MIIEvQ"))
    }

    @Test("many BEGIN lines with no END do not take quadratic time")
    func noBacktracking() {
        let text = String(repeating: "-----BEGIN RSA PRIVATE KEY-----\n", count: 6_000)
        let start = ContinuousClock.now
        _ = ContextRedactor.redact(text)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("a redacted value is not redacted again")
    func stable() {
        let once = ContextRedactor.redact(#"password = "hunter2hunter2""#)
        let twice = ContextRedactor.redact(once.text)
        #expect(twice.count == 0 && twice.text == once.text)
    }

    @Test("a long run of identifier characters does not make redaction slow")
    func longRunIsFast() {
        let start = Date()
        _ = ContextRedactor.redact(String(repeating: "a", count: 20_000))
        _ = ContextRedactor.redact(String(repeating: "ab.", count: 7_000))
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("a long credential name still redacts its value")
    func longNameStillRedacts() {
        let out = ContextRedactor.redact(#"MY_SERVICE_API_KEY_PRODUCTION = "hunter2hunter2""#)
        #expect(out.count == 1 && !out.text.contains("hunter2"))
    }
}
