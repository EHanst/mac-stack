import Testing
import Foundation
@testable import StackCore

@Suite("ASTChunker line numbers")
struct ASTChunkerLineTests {

    private func chunk(_ source: String, kind: String = "func") async -> CodeChunk? {
        await ASTChunker().chunks(source: source, filePath: "/ws/A.swift").first { $0.declarationKind == kind }
    }

    @Test("a declaration after blank lines and a comment starts on its own first line")
    func startSkipsLeadingTrivia() async throws {
        let c = try #require(await chunk("let a = 1\n\n// note\nfunc f() {\n    print(1)\n}\n"))
        #expect(c.startLine == 4)
        #expect(c.endLine == 6)
    }

    @Test("the last declaration of a file with no trailing newline ends on the last line")
    func noTrailingNewline() async throws {
        let c = try #require(await chunk("func f() {\n}"))
        #expect(c.startLine == 1 && c.endLine == 2)
    }

    @Test("CRLF files count lines the same way")
    func crlf() async throws {
        let c = try #require(await chunk("let a = 1\r\n\r\nfunc f() {\r\n}\r\n"))
        #expect(c.startLine == 3 && c.endLine == 4)
    }

    @Test("lines are counted in bytes, so multibyte text before a declaration does not shift them")
    func multibyte() async throws {
        let c = try #require(await chunk("let s = \"héllo — 日本語\"\nfunc f() {}\n"))
        #expect(c.startLine == 2 && c.endLine == 2)
    }
}
