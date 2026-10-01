#if canImport(AppKit)
#if SWIFT_PACKAGE
import KororoCore
import StackCore
#endif
import SwiftUI

/// Readable markdown rendering for brief text. Block structure comes from the pure
/// `MarkdownBlocks` parser; inline formatting is handled by AttributedString.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 12) {
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
                .padding(.top, level <= 2 ? 8 : 4)

        case .list(let items):
            listView(items, depth: 0)

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
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listView(_ items: [MarkdownListItem], depth: Int) -> AnyView {
        let bullets = ["•", "◦", "▪"]
        return AnyView(
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    let item = items[i]
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.ordered ? "\(item.number)." : bullets[min(depth, 2)])
                                .font(.mtBodyMedium.monospacedDigit())
                                .foregroundStyle(item.ordered ? Color.mtOnSurfaceVariant : Color.mtOnSurfaceVariant.opacity(0.8))
                                .frame(minWidth: item.ordered ? 22 : 12, alignment: .trailing)
                            Text(attributed(item.text))
                                .font(.mtBodyMedium)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !item.children.isEmpty {
                            listView(item.children, depth: depth + 1)
                                .padding(.leading, 26)
                        }
                    }
                }
            }
        )
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return AppTypography.font(size: 20, weight: .semibold)
        case 2: return AppTypography.font(size: 17, weight: .semibold)
        default: return AppTypography.font(size: 14, weight: .semibold)
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
