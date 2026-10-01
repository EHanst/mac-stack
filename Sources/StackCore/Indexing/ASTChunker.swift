import Foundation
import SwiftParser
import SwiftSyntax
import Crypto

public struct CodeChunk: Sendable, Hashable {
    public let id: UUID
    public let filePath: String
    public let declarationKind: String
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let contentHash: Data

    public init(filePath: String, declarationKind: String,
                startLine: Int, endLine: Int, content: String) {
        let hash = Data(SHA256.hash(data: Data(content.utf8)))
        self.filePath = filePath
        self.declarationKind = declarationKind
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.contentHash = hash
        // Same file + same text = same id, so re-indexing keeps rows (and their embeddings) instead of duplicating them.
        var seed = Data(filePath.utf8)
        seed.append(0)
        seed.append(hash)
        let d = Array(SHA256.hash(data: seed))
        self.id = UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }
}

/// Splits Swift source files into declaration-boundary chunks using SwiftSyntax.
public actor ASTChunker {

    public init() {}

    public func chunks(for fileURL: URL) async throws -> [CodeChunk] {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        return chunks(source: source, filePath: fileURL.path)
    }

    public func chunks(source: String, filePath: String) -> [CodeChunk] {
        let tree = Parser.parse(source: source)
        let visitor = DeclarationVisitor(source: source, filePath: filePath)
        visitor.walk(tree)
        return visitor.chunks
    }
}

// MARK: - SyntaxVisitor

private final class DeclarationVisitor: SyntaxVisitor {

    var chunks: [CodeChunk] = []
    let source: String
    let filePath: String
    /// UTF-8 offset where each line starts; SwiftSyntax positions are UTF-8 offsets.
    let lineStarts: [Int]

    init(source: String, filePath: String) {
        self.source = source
        self.filePath = filePath
        var starts = [0]
        for (offset, byte) in source.utf8.enumerated() where byte == 0x0A { starts.append(offset + 1) }
        self.lineStarts = starts
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node: node, kind: "func")
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node: node, kind: "struct")
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node: node, kind: "class")
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node: node, kind: "enum")
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node: node, kind: "protocol")
        return .skipChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node: node, kind: "extension")
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node: node, kind: "actor")
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node: node, kind: "typealias")
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Only top-level vars (no parent function/init context)
        if node.parent?.is(CodeBlockItemSyntax.self) == true ||
           node.parent?.is(MemberBlockItemSyntax.self) == true {
            record(node: node, kind: "var")
        }
        return .skipChildren
    }

    private func record(node: some SyntaxProtocol, kind: String) {
        let content = node.description
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1-based lines of the declaration itself (without leading comments or blank lines)
        let startOffset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let endOffset = node.endPositionBeforeTrailingTrivia.utf8Offset
        let startLine = lineNumber(at: startOffset)
        let endLine = lineNumber(at: endOffset)

        chunks.append(CodeChunk(
            filePath: filePath,
            declarationKind: kind,
            startLine: startLine,
            endLine: endLine,
            content: trimmed
        ))
    }

    /// 1-based line holding `utf8Offset`: the last line that starts at or before it.
    private func lineNumber(at utf8Offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= utf8Offset { low = mid + 1 } else { high = mid }
        }
        return max(low, 1)
    }
}
