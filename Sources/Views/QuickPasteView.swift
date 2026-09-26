import AppKit
import SwiftUI

/// The palette shown by ⌥⌘V, and the menu bar's "quick look" at the clipboard.
///
/// Entirely keyboard-driven: type to filter, ↑↓ to move, ⌘1–9 to jump, ⏎ to
/// paste, ⌥⏎ to paste without formatting, Space to preview, ⌘⌫ to delete.
struct QuickPasteView: View {
    /// Grows with the text-size setting so the same number of rows stays visible.
    @MainActor
    static var panelSize: CGSize {
        let scale = AppSettings.shared.textSize.metricScale
        return CGSize(width: (460 * min(scale, 1.25)).rounded(), height: (540 * min(scale, 1.2)).rounded())
    }

    let onSelect: (ClipboardItem, Bool) -> Void
    let onDismiss: () -> Void

    @Environment(ClipboardStore.self) private var store
    @State private var searchText = ""
    @State private var selection = 0
    @State private var previewItem: ClipboardItem?
    @FocusState private var searchFocused: Bool

    /// Hover reports a row as hovered whenever the row moves under a stationary
    /// cursor, which happens on every scroll and every arrow key. Taking that as
    /// intent fought the keyboard (the selection snapped back under the mouse)
    /// and fed the scroll loop below. We only accept hover once the mouse has
    /// actually moved.
    @State private var lastMouseLocation = NSEvent.mouseLocation
    /// True while the selection is being driven from the keyboard; only then do
    /// we scroll to follow it.
    @State private var isKeyboardDriven = false

    private var results: [ClipboardItem] {
        let all = store.items
        guard !searchText.isEmpty else { return Array(all.prefix(200)) }
        let query = searchText.lowercased()
        return all.filter { $0.searchCorpus.contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            if let previewItem {
                Divider()
                // A sheet cannot present over a floating panel, and a second
                // window would steal focus from the palette. The preview lives
                // inside the palette instead.
                InlineClipPreview(item: previewItem) { self.previewItem = nil }
                    .frame(height: 230)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            footer
        }
        // The palette owns its size. Without an explicit frame the hosting view
        // reports the fitting size of a ScrollView — which is nothing — and the
        // borderless panel shrinks to a stub.
        .frame(width: QuickPasteView.panelSize.width, height: QuickPasteView.panelSize.height)
        // A solid surface, not `.regularMaterial`. AppKit's visual effect view
        // draws its own hairline along the edge, and clipped to a rounded
        // rectangle that reads as a grey ring traced round the palette. The
        // panel's shadow is what should separate it from the desktop.
        .background(Theme.elevated)
        // The rounding is done by the panel's layer, not here. A SwiftUI
        // `clipShape` antialiases its own cut, and against a light background
        // that half-covered pixel reads as a grey line traced round the whole
        // palette — measured at #808080, one pixel wide, following the curve.
        // No outline: the panel's shadow is what separates it from whatever is
        // behind, and a hairline on top of that only reads as a grey ring.
        .onAppear {
            searchFocused = true
            lastMouseLocation = NSEvent.mouseLocation
        }
        .onChange(of: searchText) {
            isKeyboardDriven = true
            selection = 0
        }
    }

    // MARK: - Sections

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("Search clips"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { pasteSelected(plainText: false) }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.hoverPlate(padding: 2, cornerRadius: 10))
                .accessibilityLabel(L("Clear search"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        if results.isEmpty {
            EmptyStateView(
                icon: searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                title: searchText.isEmpty ? L("Nothing copied yet") : L("No matches"),
                message: searchText.isEmpty
                    ? L("Copy something and it will appear here.")
                    : L("No clip contains “\(searchText)”.")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            QuickPasteRow(
                                item: item,
                                index: index,
                                isSelected: index == selection,
                                onPreview: { preview(item) }
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = index
                                onSelect(item, false)
                            }
                            .onHover { hovering in
                                guard hovering else { return }
                                let location = NSEvent.mouseLocation
                                guard location != lastMouseLocation else { return }
                                lastMouseLocation = location
                                isKeyboardDriven = false
                                selection = index
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: selection) { _, new in
                    // Scrolling to follow the mouse is what made the list bolt:
                    // a scroll moved a row under the cursor, hover reselected it,
                    // and this scrolled again. Follow the keyboard only.
                    guard isKeyboardDriven else { return }
                    // `nil` scrolls the minimum distance to reveal the row;
                    // `.center` re-centred on every step and looked like a jump.
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: nil) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ShortcutHint(keys: "↩", label: L("Copy"))
            ShortcutHint(keys: "⌥↩", label: L("Plain"))
            ShortcutHint(keys: "⌘1–9", label: L("Jump"))
            ShortcutHint(keys: "⌘Y", label: L("Preview"))
            Spacer()
            Text(L("\(results.count)"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .elevatedSurface()
        .overlay(alignment: .center) { keyboardCommands }
    }

    /// Invisible buttons that carry the palette's key equivalents.
    private var keyboardCommands: some View {
        ZStack {
            Button("") { move(by: 1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { move(by: -1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(by: 8) }.keyboardShortcut(.pageDown, modifiers: [])
            Button("") { move(by: -8) }.keyboardShortcut(.pageUp, modifiers: [])
            Button("") { pasteSelected(plainText: false) }.keyboardShortcut(.return, modifiers: [])
            Button("") { pasteSelected(plainText: true) }.keyboardShortcut(.return, modifiers: .option)
            // Quick Look's Space belongs to the search field here — it is always
            // focused, so the field swallows the key before any shortcut sees it.
            // ⌘Y is Finder's other Quick Look binding and stays free while typing.
            Button("") { showPreview() }.keyboardShortcut("y", modifiers: .command)
            Button("") { deleteSelected() }.keyboardShortcut(.delete, modifiers: .command)
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { onDismiss() }.keyboardShortcut(.escape, modifiers: [])
            ForEach(1...9, id: \.self) { number in
                Button("") { jump(to: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        isKeyboardDriven = true
        lastMouseLocation = NSEvent.mouseLocation
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func jump(to index: Int) {
        guard results.indices.contains(index) else { return }
        isKeyboardDriven = true
        selection = index
        onSelect(results[index], false)
    }

    private func pasteSelected(plainText: Bool) {
        guard results.indices.contains(selection) else { return }
        onSelect(results[selection], plainText)
    }

    private func showPreview() {
        guard results.indices.contains(selection) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            previewItem = (previewItem?.id == results[selection].id) ? nil : results[selection]
        }
    }

    private func preview(_ item: ClipboardItem) {
        withAnimation(.easeOut(duration: 0.15)) {
            previewItem = (previewItem?.id == item.id) ? nil : item
        }
    }

    private func deleteSelected() {
        guard results.indices.contains(selection) else { return }
        store.delete(results[selection])
        selection = min(selection, max(results.count - 2, 0))
    }
}

struct QuickPasteRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    var onPreview: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if index < 9 {
                Text(L("\(index + 1)"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .tertiary)
                    .frame(width: 14)
            } else {
                Spacer().frame(width: 14)
            }

            if let thumbnail = item.thumbnailImage {
                Button { onPreview?() } label: {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Theme.Metric.iconSize, height: Theme.Metric.iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.corner))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metric.corner)
                                .stroke(Theme.separator, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.hoverLift(scale: 1.06))
                .help(L("Show this image"))
            } else {
                TypeBadge(type: item.type)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.previewText)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.type == .image, item.recognizedFirstLine != nil {
                        Image(systemName: "text.viewfinder")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    if item.type == .image {
                        let summary = item.imageSummary
                        if !summary.isEmpty {
                            Text(summary)
                            Text(verbatim: "·")
                        }
                    }
                    if let app = item.sourceApp {
                        Text(app)
                        Text(verbatim: "·")
                    }
                    Text(item.createdAt.relativeFormatted)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.Metric.rowHeight)
        .background(isSelected ? Theme.selection.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Metric.corner))
    }
}

/// Full preview of a clip: the image at full size, and the text recognised in
/// it shown separately so it can be read and copied on its own.
struct ClipPreviewSheet: View {
    let item: ClipboardItem
    let onClose: () -> Void

    @State private var copiedRecognisedText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    body(for: item)
                    if item.type == .image { recognisedTextSection }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let thumbnail = item.thumbnailImage {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.corner))
            } else {
                TypeBadge(type: item.type, size: 30)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(L("Copy")) {
                guard let content = item.pasteContent else { return }
                PasteService.write(content)
            }
            Button(L("Done"), action: onClose)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var subtitle: String {
        var parts = [item.type.displayName]
        if item.type == .image {
            let summary = item.imageSummary
            if !summary.isEmpty { parts.append(summary) }
        }
        if let app = item.sourceApp { parts.append(app) }
        parts.append(item.createdAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened, locale: LanguageBundle.locale)))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func body(for item: ClipboardItem) -> some View {
        if let image = item.imageData.flatMap(NSImage.init(data:)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.separator, lineWidth: 0.5)
                )
        } else if item.type == .image {
            EmptyStateView(
                icon: "photo.badge.exclamationmark",
                title: L("Image unavailable"),
                message: L("The stored file for this clip could not be read.")
            )
            .frame(height: 160)
        } else if item.isSensitive {
            Text(L("This item is stored encrypted and is not shown in previews."))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text(item.displayBody)
                .font(item.type == .code ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var recognisedTextSection: some View {
        Divider()
        HStack {
            Label(L("Recognised text"), systemImage: "text.viewfinder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let recognised = item.extractedText, !recognised.isEmpty {
                Button(copiedRecognisedText ? L("Copied") : L("Copy Text")) {
                    PasteService.write(.text(recognised))
                    copiedRecognisedText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedRecognisedText = false
                    }
                }
                .buttonStyle(.hoverLink)
                .font(.caption)
            }
        }

        if let recognised = item.extractedText, !recognised.isEmpty {
            Text(recognised)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text(L("No text was found in this image."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}


/// Preview shown inside the palette and the menu bar popover.
///
/// Neither surface can present a sheet: a floating panel has nothing to attach
/// one to, and a popover closes when another window takes focus. Showing the
/// preview in place avoids both problems and keeps the list visible.
struct InlineClipPreview: View {
    let item: ClipboardItem
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    visual
                    recognisedText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 8)
        .background(Theme.secondaryBackground.opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: item.type == .image ? "photo" : "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.hoverPlate(padding: 2, cornerRadius: 10))
            .help(L("Close preview"))
        }
        .padding(.horizontal, 10)
    }

    private var subtitle: String {
        var parts: [String] = []
        if item.type == .image {
            let summary = item.imageSummary
            parts.append(summary.isEmpty ? L("Image") : summary)
        } else {
            parts.append(item.type.displayName)
        }
        if let app = item.sourceApp { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var visual: some View {
        if let image = item.imageData.flatMap(NSImage.init(data:)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.separator, lineWidth: 0.5)
                )
        } else if item.type == .image {
            Text(L("The stored file for this image could not be read."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if item.isSensitive {
            Text(L("Stored encrypted; not shown in previews."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(item.displayBody)
                .font(item.type == .code ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var recognisedText: some View {
        if item.type == .image {
            HStack(spacing: 5) {
                Label(L("Recognised text"), systemImage: "text.viewfinder")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let recognised = item.extractedText, !recognised.isEmpty {
                    Button(copied ? L("Copied") : L("Copy")) {
                        PasteService.write(.text(recognised))
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .buttonStyle(.hoverLink)
                    .font(.caption2)
                }
            }

            if let recognised = item.extractedText, !recognised.isEmpty {
                Text(recognised)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(L("No text was found in this image."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
