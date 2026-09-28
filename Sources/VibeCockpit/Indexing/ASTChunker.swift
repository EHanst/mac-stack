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
        self.id = UUID()
        self.filePath = filePath
        self.declarationKind = declarationKind
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.contentHash = Data(SHA256.hash(data: Data(content.utf8)))
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
    let lines: [Substring]

    init(source: String, filePath: String) {
        self.source = source
        self.filePath = filePath
        self.lines = source.split(separator: "\n", omittingEmptySubsequences: false)
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

        // Estimate line numbers from source position
        let startOffset = node.position.utf8Offset
        let endOffset = node.endPosition.utf8Offset
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

    private func lineNumber(at utf8Offset: Int) -> Int {
        var count = 0
        var current = 0
        for line in lines {
            let lineLen = line.utf8.count + 1 // +1 for newline
            if current + lineLen > utf8Offset { return count + 1 }
            current += lineLen
            count += 1
        }
        return count + 1
    }
}
