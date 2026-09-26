import AppKit
import SwiftUI

/// One row of clipboard history.
///
/// Fixed height, monochrome symbols, no gradients: the list should read like
/// Mail or Xcode's navigator, dense and scannable, not like a card feed.
struct ClipboardItemRow: View {
    let item: ClipboardItem
    let onPaste: () -> Void
    let onPreview: () -> Void

    @Environment(ClipboardStore.self) private var store
    @State private var isHovered: Bool
    @State private var showCopiedTick = false

    /// `hovered` starts the row under the pointer; the development
    /// diagnostics use it to picture the hover state without a mouse.
    init(item: ClipboardItem, hovered: Bool = false, onPaste: @escaping () -> Void, onPreview: @escaping () -> Void) {
        self.item = item
        self.onPaste = onPaste
        self.onPreview = onPreview
        _isHovered = State(initialValue: hovered)
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.previewText)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.isSensitive ? .secondary : .primary)

                    // An image row leads with the text found in it, so mark that
                    // the words come from the picture rather than from a copy.
                    if item.type == .image, item.recognizedFirstLine != nil {
                        Image(systemName: "text.viewfinder")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help(L("Text recognised in this image"))
                    }
                }

                HStack(spacing: 5) {
                    Text(item.type.displayName)
                    if item.type == .image {
                        let summary = item.imageSummary
                        if !summary.isEmpty {
                            Text(verbatim: "·")
                            Text(summary)
                        }
                    }
                    if let app = item.sourceApp {
                        Text(verbatim: "·")
                        Text(app)
                    }
                    Text(verbatim: "·")
                    Text(item.createdAt.relativeFormatted)
                    if item.type != .image, !item.tags.isEmpty {
                        Text(verbatim: "·")
                        Text(item.tags.prefix(2).joined(separator: ", "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            // Only what never changes on hover takes part in the layout. The
            // buttons used to replace this star in the row itself, which took
            // their width away from the text: it re-truncated, and the whole
            // line jumped every time the pointer crossed it.
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.Metric.rowHeight)
        // Under the buttons the text fades out instead of being cut through
        // mid-word by them.
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                if isHovered || showCopiedTick {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 40)
                    Color.clear.frame(width: Self.actionsWidth)
                }
            }
        }
        // The whole row lights up under the pointer, so it is plain which
        // clip a double-click or the buttons will act on.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        .overlay(alignment: .trailing) {
            // The buttons float over the end of the row instead.
            Group {
                if showCopiedTick {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                } else if isHovered {
                    actions
                }
            }
            .padding(.trailing, 8)
            .transition(.opacity)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = hovering }
        }
        .onTapGesture(count: 2) { onPaste() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("\(item.type.displayName). \(item.previewText)"))
        // A Mac is clicked, not tapped. VoiceOver read the iOS wording out
        // loud to people who have no touchscreen.
        .accessibilityHint(L("Double-click to paste"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = item.thumbnailImage {
            // Clicking the picture is the obvious way to ask "what is this?",
            // so the thumbnail itself opens the preview.
            Button(action: onPreview) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Theme.Metric.iconSize, height: Theme.Metric.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metric.corner)
                            .stroke(Theme.separator, lineWidth: 0.5)
                    )
                    .overlay {
                        if isHovered {
                            RoundedRectangle(cornerRadius: Theme.Metric.corner)
                                .fill(.black.opacity(0.35))
                                .overlay(
                                    Image(systemName: "eye")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                )
                        }
                    }
            }
            .buttonStyle(.hoverLift(scale: 1.06))
            .help(L("Show this image"))
            .accessibilityLabel(L("Show image"))
        } else {
            // Not only images: clicking the badge of any clip opens its preview,
            // which is the only way to read a long clip in full.
            Button(action: onPreview) {
                TypeBadge(type: item.type)
                    .overlay {
                        if isHovered {
                            RoundedRectangle(cornerRadius: Theme.Metric.corner)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    Image(systemName: "eye")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                )
                        }
                    }
            }
            .buttonStyle(.hoverLift(scale: 1.06))
            .help(L("Show this clip"))
            .accessibilityLabel(L("Show clip"))
        }
    }

    /// Four buttons of 22 points with a 2-point plate each, and their spacing.
    private static let actionsWidth: CGFloat = 4 * 26 + 3 * 2 + 8

    private var actions: some View {
        HStack(spacing: 2) {
            rowButton("eye", help: L("Quick Look"), action: onPreview)
            rowButton(item.isFavorite ? "star.fill" : "star", help: L("Favourite")) {
                store.toggleFavorite(item)
            }
            rowButton("doc.on.doc", help: L("Copy")) {
                guard let content = item.pasteContent else { return }
                PasteService.write(content)
                store.recordUse(item)
                withAnimation { showCopiedTick = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    withAnimation { showCopiedTick = false }
                }
            }
            rowButton("trash", help: L("Delete")) { store.delete(item) }
        }
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlate(padding: 2))
        .help(help)
    }
}
