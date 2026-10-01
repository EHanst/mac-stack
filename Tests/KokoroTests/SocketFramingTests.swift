import Testing
import Foundation
@testable import StackMCP

@Suite("Socket framing")
struct SocketFramingTests {

    private func lines(_ result: NewlineSplitter.Result) -> [String] {
        result.lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("complete lines come out; a partial line waits for the next chunk")
    func partialLines() {
        var splitter = NewlineSplitter(maxLineBytes: 1024)
        #expect(lines(splitter.feed(Array("{\"a\":1}\n{\"b\"".utf8))) == ["{\"a\":1}"])
        #expect(lines(splitter.feed(Array(":2}\n".utf8))) == ["{\"b\":2}"])
    }

    @Test("blank lines are dropped and many lines in one chunk keep their order")
    func manyLines() {
        var splitter = NewlineSplitter(maxLineBytes: 1 << 20)
        let chunk = (0..<5000).map { "m\($0)\n\n" }.joined()
        let out = lines(splitter.feed(Array(chunk.utf8)))
        #expect(out.count == 5000)
        #expect(out.first == "m0" && out.last == "m4999")
    }

    @Test("a line longer than the cap with no newline is refused")
    func overflow() {
        var splitter = NewlineSplitter(maxLineBytes: 16)
        #expect(splitter.feed(Array("0123456789".utf8)).overflow == false)
        #expect(splitter.feed(Array("0123456789".utf8)).overflow == true)
    }

    @Test("a long line that does end within the cap is fine")
    func longButTerminated() {
        var splitter = NewlineSplitter(maxLineBytes: 16)
        let r = splitter.feed(Array("0123456789abcd\n".utf8))
        #expect(r.overflow == false)
        #expect(lines(r) == ["0123456789abcd"])
    }

    @Test("an interrupted system call is retried, not treated as a closed connection")
    func retriesInterrupted() {
        var calls = 0
        let n = retryingOnEINTR { () -> Int in
            calls += 1
            if calls < 3 { errno = EINTR; return -1 }
            return 5
        }
        #expect(n == 5 && calls == 3)
    }

    @Test("other errors are returned as they are")
    func otherErrorsPass() {
        let n = retryingOnEINTR { () -> Int in errno = EBADF; return -1 }
        #expect(n == -1)
    }
}
