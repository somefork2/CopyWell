import AppKit
import SwiftData
import SwiftUI

struct ClipboardListView: View {
    let items: [ClipboardItem]
    let searchText: String
    @Binding var typeFilter: ContentType?

    @Environment(ClipboardStore.self) private var store
    @State private var selection: PersistentIdentifier?
    @State private var previewItem: ClipboardItem?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .sheet(item: $previewItem) { item in
            ClipPreviewSheet(item: item) { previewItem = nil }
        }
        .overlay { keyboardCommands }
        .onReceive(NotificationCenter.default.publisher(for: .copyWellRequestPreviewSelection)) { _ in
            previewSelection()
        }
    }

    /// Keyboard equivalents for the selected row. The list is the focus here, so
    /// Space is free — unlike in the palette, where the search field owns it.
    private var keyboardCommands: some View {
        ZStack {
            Button("") { previewSelection() }.keyboardShortcut(.space, modifiers: [])
            Button("") { pasteSelection() }.keyboardShortcut(.return, modifiers: [])
            Button("") { pasteSelection(plainText: true) }.keyboardShortcut(.return, modifiers: .option)
            Button("") { favoriteSelection() }.keyboardShortcut("d", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// The row the user has selected, or the first one when nothing is selected
    /// yet — pressing Space on a fresh list should show something.
    private var selectedItem: ClipboardItem? {
        if let selection, let item = items.first(where: { $0.persistentModelID == selection }) {
            return item
        }
        return items.first
    }

    private func previewSelection() {
        guard let item = selectedItem else { return }
        previewItem = item
    }

    private func pasteSelection(plainText: Bool = false) {
        guard let item = selectedItem else { return }
        paste(item, plainText: plainText)
    }

    private func favoriteSelection() {
        guard let item = selectedItem else { return }
        store.toggleFavorite(item)
    }

    // MARK: - Filter bar

    /// The chips, in a horizontal scroller because there can be more of them
    /// than fit.
    ///
    /// The background is ours because a `ScrollView` paints none of its own: the
    /// strip stayed the same near-black whatever the theme, indistinguishable
    /// under the dark themes and a black bar across the top under Light and
    /// Paper. It is needed twice over now that this is a pinned header — rows
    /// scroll underneath it, and a transparent header would show them through.
    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                FilterChip(title: L("All"), isSelected: typeFilter == nil) { typeFilter = nil }
                ForEach(availableTypes, id: \.self) { type in
                    FilterChip(
                        title: type.displayName,
                        systemImage: type.systemImage,
                        isSelected: typeFilter == type
                    ) {
                        typeFilter = typeFilter == type ? nil : type
                    }
                }
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
    }

    /// Only offer filters for types that actually occur in the history.
    ///
    /// Deliberately over the whole store and not over `items`: `items` is
    /// already filtered, so building the chips from it would leave only the
    /// chip for the active filter and no way back to the others. The walk stops
    /// as soon as every type has been seen, which on a full history is a few
    /// clips rather than all of them.
    private var availableTypes: [ContentType] {
        var present = Set<ContentType>()
        for item in store.items {
            present.insert(item.type)
            if present.count == ContentType.allCases.count { break }
        }
        return ContentType.allCases.filter { present.contains($0) }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            EmptyStateView(
                icon: searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                title: searchText.isEmpty ? L("No clips here yet") : L("No matches"),
                message: searchText.isEmpty
                    ? L("Copy anything and it appears here. Press ⌥⌘V anywhere to paste it back.")
                    : L("Nothing matches “\(searchText)”.")
            )
        } else {
            List(selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ClipboardItemRow(
                        item: item,
                        onPaste: { paste(item, plainText: false) },
                        onPreview: { previewItem = item }
                    )
                    .tag(item.persistentModelID)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    // No zebra stripes and no rules between rows: with the
                    // hover highlight on top they made three overlapping
                    // bands of shading, each a different shape.
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        ClipContextMenu(
                            item: item,
                            onPaste: { paste(item, plainText: false) },
                            onPastePlain: { paste(item, plainText: true) },
                            onPreview: { previewItem = item }
                        )
                    }
                    }
            }
            .listStyle(.inset)
            .themedScrollBackground()
            .contextMenu {
                Button(L("Clear History…")) {
                    NotificationCenter.default.post(name: .copyWellRequestClearHistory, object: nil)
                }
            }
            .onDeleteCommand { deleteSelection() }
        }
    }

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        guard let content = item.pasteContent else { return }
        store.recordUse(item)
        StatisticsTracker.shared.recordPaste()
        PasteService.write(content, plainText: plainText)
    }

    private func deleteSelection() {
        guard let selection,
              let item = items.first(where: { $0.persistentModelID == selection }) else { return }
        store.delete(item)
    }
}

struct FilterChip: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                }
                Text(title)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isSelected ? AnyShapeStyle(Theme.accent.opacity(0.18)) : AnyShapeStyle(Theme.secondaryBackground),
                in: Capsule()
            )
            // strokeBorder at a full point, not stroke at half of one.
            //
            // `stroke` centres the line on the outline, so half of a hairline
            // falls outside the view and is clipped; what was left rendered only
            // where the capsule's edge runs vertical, as two short bars either
            // side of every chip with nothing along the top. It read exactly
            // like the chips had their tops cut off. `strokeBorder` keeps the
            // whole line inside, and a full point actually covers the curve.
            .overlay(Capsule().strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Theme.separator, lineWidth: 1))
        }
        .buttonStyle(.hoverLift(scale: 1.04))
    }
}
