import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("GenerationSupport")
struct GenerationSupportTests {

    // MARK: commonPrefixLength

    @Test("common prefix length of identical, diverging and empty arrays")
    func prefixLength() {
        #expect(commonPrefixLength([1, 2, 3], [1, 2, 3]) == 3)
        #expect(commonPrefixLength([1, 2, 3], [1, 2, 9, 4]) == 2)
        #expect(commonPrefixLength([1, 2], [1, 2, 3, 4]) == 2)
        #expect(commonPrefixLength([Int32](), [1, 2]) == 0)
        #expect(commonPrefixLength([5], [6]) == 0)
    }

    // MARK: StreamingDetokenizer

    /// Fake byte-level tokenizer: token n < 256 is byte n; decoding replaces invalid UTF-8
    /// with U+FFFD, exactly like a real lone-byte-token decode.
    private static func byteDecode(_ tokens: [Int]) -> String {
        String(decoding: tokens.map { UInt8($0) }, as: UTF8.self)
    }

    @Test("ASCII tokens pass straight through")
    func detokenizerAscii() {
        var d = StreamingDetokenizer(decode: Self.byteDecode)
        #expect(d.append(Int(UInt8(ascii: "h"))) == "h")
        #expect(d.append(Int(UInt8(ascii: "i"))) == "i")
        #expect(d.flush() == "")
    }

    @Test("multi-byte character split across tokens is emitted whole")
    func detokenizerSplitCharacter() {
        var d = StreamingDetokenizer(decode: Self.byteDecode)
        let bytes = Array("é".utf8).map { Int($0) }  // 0xC3 0xA9
        #expect(bytes.count == 2)
        #expect(d.append(bytes[0]) == "")
        #expect(d.append(bytes[1]) == "é")
    }

    @Test("four-byte emoji is held until complete")
    func detokenizerEmoji() {
        var d = StreamingDetokenizer(decode: Self.byteDecode)
        let bytes = Array("😀".utf8).map { Int($0) }
        #expect(bytes.count == 4)
        #expect(d.append(bytes[0]) == "")
        #expect(d.append(bytes[1]) == "")
        #expect(d.append(bytes[2]) == "")
        #expect(d.append(bytes[3]) == "😀")
    }

    @Test("flush releases an incomplete trailing sequence")
    func detokenizerFlush() {
        var d = StreamingDetokenizer(decode: Self.byteDecode)
        _ = d.append(0xC3)
        #expect(d.flush() == "\u{FFFD}")
        #expect(d.flush() == "")
    }

    // MARK: StopSequenceFilter

    @Test("no stop sequences is a pass-through")
    func filterPassThrough() {
        var f = StopSequenceFilter(stops: [])
        let r = f.push("hello")
        #expect(r.emit == "hello")
        #expect(!r.stopped)
        #expect(f.flush() == "")
    }

    @Test("stop sequence within one chunk truncates output")
    func filterSingleChunk() {
        var f = StopSequenceFilter(stops: ["END"])
        let r = f.push("abcENDdef")
        #expect(r.emit == "abc")
        #expect(r.stopped)
    }

    @Test("stop sequence straddling chunks is caught and never emitted")
    func filterAcrossChunks() {
        var f = StopSequenceFilter(stops: ["STOP"])
        var out = ""
        var stopped = false
        for chunk in ["ab", "ST", "O", "Pxyz"] {
            let r = f.push(chunk)
            out += r.emit
            if r.stopped { stopped = true; break }
        }
        #expect(stopped)
        #expect(out == "ab")
    }

    @Test("held-back text is released by flush when no stop occurs")
    func filterFlush() {
        var f = StopSequenceFilter(stops: ["STOP"])
        var out = ""
        for chunk in ["hello ", "wor", "ld"] {
            let r = f.push(chunk)
            #expect(!r.stopped)
            out += r.emit
        }
        out += f.flush()
        #expect(out == "hello world")
    }

    @Test("earliest of several stop sequences wins")
    func filterEarliest() {
        var f = StopSequenceFilter(stops: ["cc", "bb"])
        let r = f.push("aabbcc")
        #expect(r.emit == "aa")
        #expect(r.stopped)
    }
}
