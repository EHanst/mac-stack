import Testing
import Foundation
@testable import StackCore

@Suite("KnowledgeEval")
struct KnowledgeEvalTests {
    func brief(_ title: String) -> Brief { Brief.new(title: title, target: .make(modelFamily: "claude", surface: .claudeCode)) }

    @Test("compares parse success and item counts with and without guidance")
    func compares() async {
        let rows = await KnowledgeEval.compare(briefs: [brief("a"), brief("b")]) { b, withGuidance in
            if b.title == "b" && !withGuidance { throw SidecarError.unusable }
            var r = SidecarResult()
            if withGuidance { r.findings = [SidecarFinding(id: "1", section: .goal, issue: "x", addition: nil)] }
            return r
        }
        #expect(rows[0] == KnowledgeEvalRow(title: "a", withParsed: true, withoutParsed: false, withCount: 1, withoutCount: 0))
        #expect(rows[1].withoutParsed == false && rows[1].withParsed == true)
    }

    @Test("the summary reports totals for both arms")
    func summary() {
        let rows = [KnowledgeEvalRow(title: "a", withParsed: true, withoutParsed: false, withCount: 2, withoutCount: 0)]
        let s = KnowledgeEval.summary(rows)
        #expect(s.contains("with guidance: 1/1 parsed, 2 items"))
        #expect(s.contains("without guidance: 0/1 parsed, 0 items"))
    }
}

@Suite("KnowledgeIsolation")
struct KnowledgeIsolationTests {
    @Test("a code-index search never returns knowledge entries")
    func codeIndexIsSeparate() async throws {
        let knowledge = KnowledgeStore(dbURL: KnowledgeStub.tempURL(), dimension: KnowledgeStub.dim, embedder: KnowledgeStub.embedder())
        try await knowledge.addAll([KnowledgeEntry(kind: .technique, text: "retry with exponential backoff")])
        let code = VectorStore(dbURL: KnowledgeStub.tempURL(), embeddingDimension: KnowledgeStub.dim)
        try await code.open()
        let hits = try await code.hybridSearch(query: "retry backoff", queryEmbedding: KnowledgeStub.vector("retry backoff"), topK: 5)
        #expect(hits.isEmpty)
    }

    @Test("the knowledge store lives apart from the code index")
    func separateFile() {
        #expect(KnowledgeStore.defaultURL().lastPathComponent == "knowledge.db")
        #expect(!KnowledgeStore.defaultURL().path.contains(".vibe"))
    }
}
