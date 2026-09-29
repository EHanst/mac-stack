import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("BuildFailureFingerprint")
struct BuildFailureFingerprintTests {

    @Test("same logical error with different paths produces same fingerprint")
    func normalizesPaths() {
        let a = "/Users/alice/project/Sources/Foo.swift:12:5: error: cannot find 'Bar' in scope"
        let b = "/Users/bob/workspace/AnotherProject/Sources/Foo.swift:99:3: error: cannot find 'Bar' in scope"
        let fpA = BuildFailureFingerprint(normalizing: a)
        let fpB = BuildFailureFingerprint(normalizing: b)
        #expect(fpA == fpB)
    }

    @Test("different errors produce different fingerprints")
    func differentErrors() {
        let a = "error: cannot find 'Foo' in scope"
        let b = "error: value of type 'String' has no member 'append'"
        let fpA = BuildFailureFingerprint(normalizing: a)
        let fpB = BuildFailureFingerprint(normalizing: b)
        #expect(fpA != fpB)
    }

    @Test("normalize strips timestamps")
    func stripsTimestamps() {
        let s = "2026-01-15 14:23:55.123 xcodebuild[1234:5678] error: build failed"
        let normalized = BuildFailureFingerprint.normalize(s)
        #expect(!normalized.contains("2026"))
        #expect(!normalized.contains("14:23"))
    }

    @Test("normalize strips line numbers from swift file paths")
    func stripsLineNumbers() {
        let s = "/ws/Foo.swift:42:8: error: use of unresolved identifier 'x'"
        let normalized = BuildFailureFingerprint.normalize(s)
        #expect(normalized.contains("error: use of unresolved identifier 'x'"))
        #expect(!normalized.contains(":42:8:"))
    }
}
