import Testing
import Foundation
@testable import KororoCore
@testable import StackCore
@testable import StackMCP

private actor URLCollector {
    var batches: [[URL]] = []
    func append(_ urls: [URL]) { batches.append(urls) }
}

@Suite("FSEventDebouncer")
struct FSEventDebouncerTests {

    @Test("debounces rapid events into one batch")
    func debounceBatch() async throws {
        let collector = URLCollector()
        let debouncer = FSEventDebouncer(delay: .milliseconds(50)) { urls in
            await collector.append(urls)
        }
        let urls = (0..<5).map { URL(fileURLWithPath: "/ws/file\($0).swift") }
        for url in urls { await debouncer.received([url]) }
        await debouncer.flush()
        let batches = await collector.batches
        #expect(batches.count == 1)
        #expect(batches[0].count == 5)
    }

    @Test("filters ignored directories")
    func filterIgnored() async throws {
        let collector = URLCollector()
        let debouncer = FSEventDebouncer(delay: .milliseconds(50)) { urls in
            await collector.append(urls)
        }
        await debouncer.received([
            URL(fileURLWithPath: "/ws/.build/debug/foo.o"),
            URL(fileURLWithPath: "/ws/Sources/Bar.swift"),
            URL(fileURLWithPath: "/ws/node_modules/pkg/index.js"),
        ])
        await debouncer.flush()
        let batches = await collector.batches
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
        #expect(batches[0][0].lastPathComponent == "Bar.swift")
    }
}
