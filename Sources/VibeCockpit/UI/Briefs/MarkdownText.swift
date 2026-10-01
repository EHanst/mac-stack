#if canImport(AppKit)
#if SWIFT_PACKAGE
import VibeCockpitCore
import StackCore
#endif
import SwiftUI

/// Readable markdown rendering for brief text. Block structure comes from the pure
/// `MarkdownBlocks` parser; inline formatting is handled by AttributedString.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(attributed(text))
                .font(headingFont(for: level))
                .foregroundStyle(level >= 3 ? Color.mtOnSurfaceVariant : Color.mtOnSurface)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.mtBodyMedium)
                        Text(attributed(items[i]))
                            .font(.mtBodyMedium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1).")
                            .font(.mtBodyMedium)
                            .foregroundStyle(Color.mtOnSurfaceVariant)
                        Text(attributed(items[i]))
                            .font(.mtBodyMedium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if !language.isEmpty {
                    Text(language).font(.mtLabelSmall).foregroundStyle(Color.mtOnSurfaceVariant)
                }
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.mtSurfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            }

        case .quote(let text):
            Text(attributed(text))
                .font(.mtBodyMedium)
                .foregroundStyle(Color.mtOnSurfaceVariant)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.mtOnSurfaceVariant.opacity(0.4))
                        .frame(width: 3)
                        .clipShape(Capsule())
                }

        case .rule:
            MTDivider()

        case .paragraph(let text):
            Text(attributed(text))
                .font(.mtBodyMedium)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .mtTitleMedium
        case 2: return .mtLabelLarge
        default: return .mtLabelLarge
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(text)
        }
    }
}
#endif
