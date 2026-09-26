import AppKit
import SwiftUI

/// The menu bar popover: the whole point is seeing and pasting recent clips
/// without ever opening the app window.
/// Closing the menu bar popover.
///
/// `MenuBarExtra(.window)` offers no way to dismiss itself and does not close
/// when something else takes focus, so opening the main window left a small
/// panel stranded on screen.
///
/// Ordering that window out directly was worse: SwiftUI still believed the
/// popover was presented, so the next click on the icon only flipped its idea
/// of the state back and the icon looked dead. Clicking the status item's own
/// button goes through SwiftUI's path, so both sides agree.
@MainActor
enum MenuBarPopover {
    static func dismiss() {
        if let button = statusItemButton() {
            button.performClick(nil)
            return
        }
        // Last resort: at least get it off the screen.
        for window in NSApp.windows where window.level == .popUpMenu && window.isVisible {
            window.orderOut(nil)
        }
    }

    /// The status item lives in a window the system owns at the status bar level;
    /// its button is the control the user actually clicks.
    private static func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.level == .statusBar {
            if let button = window.contentView as? NSStatusBarButton { return button }
            if let button = window.contentView?.subviews.compactMap({ $0 as? NSStatusBarButton }).first {
                return button
            }
        }
        return nil
    }
}

struct MenuBarContentView: View {
    @Environment(ClipboardStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var searchText = ""
    @State private var previewItem: ClipboardItem?

    private var results: [ClipboardItem] {
        guard !searchText.isEmpty else { return store.recent(limit: 12) }
        let query = searchText.lowercased()
        return Array(store.items.filter { $0.searchCorpus.contains(query) }.prefix(30))
    }

    var body: some View {
        VStack(spacing: 0) {
            if ScreenRecorder.shared.isRecording {
                recordingBanner
                Divider()
            }
            header
            Divider()
            list
            if let previewItem {
                Divider()
                InlineClipPreview(item: previewItem) { self.previewItem = nil }
                    .frame(height: 210)
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .elevatedSurface()
    }

    /// While a recording runs, the menu bar icon is the one sure way back to
    /// the Stop button — the floating one may be behind a full-screen app.
    private var recordingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(L("Recording \(RecordingClock.string(ScreenRecorder.shared.elapsed(at: context.date)))"))
                    .monospacedDigit()
            }
            Spacer()
            Button(L("Stop")) {
                MenuBarPopover.dismiss()
                ScreenRecorder.shared.stop()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField(L("Search"), text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var list: some View {
        if results.isEmpty {
            EmptyStateView(
                icon: "doc.on.clipboard",
                title: searchText.isEmpty ? L("Nothing yet") : L("No matches"),
                message: searchText.isEmpty ? L("Copy something to get started.") : L("Try another search.")
            )
            .frame(height: 140)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(results) { item in
                        Button {
                            paste(item)
                        } label: {
                            MenuBarRow(item: item) {
                                previewItem = (previewItem?.id == item.id) ? nil : item
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            ClipContextMenu(
                                item: item,
                                onPaste: { paste(item) },
                                onPastePlain: { paste(item, plainText: true) },
                                onPreview: { previewItem = item }
                            )
                        }
                    }
                }
                .padding(6)
            }
            // A ScrollView has no intrinsic height: inside a popover that sizes
            // itself to its content it collapses to nothing, so the list has to
            // state how tall it wants to be.
            .frame(height: listHeight)
        }
    }

    /// Tall enough for the rows we have, capped so the popover never runs off
    /// the screen.
    ///
    /// The cap has to come down when the inline preview is open, because that
    /// adds its own 210 points below the list. Without this the popover asked
    /// for more height than the screen has under the menu bar, and what fell
    /// off the bottom was the footer.
    private var listHeight: CGFloat {
        let rows = CGFloat(results.count)
        let content = rows * (Theme.Metric.compactRowHeight + 1) + 12
        let cap: CGFloat = previewItem == nil ? 420 : 210
        return min(max(content, Theme.Metric.compactRowHeight + 12), cap)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if coordinator.isPaused {
                Label(L("Recording paused"), systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            HStack(spacing: 10) {
                Button(L("Open CopyWell")) {
                    MenuBarPopover.dismiss()
                    coordinator.openMainWindow()
                }
                .buttonStyle(.hoverLink)

                Button(coordinator.isPaused ? L("Resume") : L("Pause")) {
                    coordinator.togglePause()
                }
                .buttonStyle(.hoverLink)

                Spacer()

                Button {
                    MenuBarPopover.dismiss()
                    // The popover has to be gone before the screen is
                    // photographed, or it is in the picture.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        AppCoordinator.unlocked { ScreenshotController.start() }
                    }
                } label: {
                    Image(systemName: "camera.viewfinder")
                }
                .buttonStyle(.hoverIcon)
                .help(L("Capture Area…"))

                Button {
                    MenuBarPopover.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        AppCoordinator.unlocked { ScreenRecorder.shared.toggle() }
                    }
                } label: {
                    Image(systemName: "record.circle")
                }
                .buttonStyle(.hoverIcon)
                .help(ScreenRecorder.shared.isRecording ? L("Stop Recording") : L("Record Screen…"))

                Button {
                    MenuBarPopover.dismiss()
                    coordinator.showSetupGuide()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.hoverIcon)
                .help(L("Setup guide"))

                Button {
                    MenuBarPopover.dismiss()
                    coordinator.openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.hoverIcon)
                .help(L("Settings"))

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.hoverIcon)
                .help(L("Quit CopyWell"))
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func paste(_ item: ClipboardItem, plainText: Bool = false) {
        // The popover has to go before the paste: it is holding focus, and the
        // keystroke needs to land in the app the user came from.
        MenuBarPopover.dismiss()
        guard let content = item.pasteContent else { return }
        store.recordUse(item)
        StatisticsTracker.shared.recordPaste()
        PasteService.deliver(content, plainText: plainText)
    }
}

struct MenuBarRow: View {
    let item: ClipboardItem
    var onPreview: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            if let thumbnail = item.thumbnailImage {
                Button { onPreview?() } label: {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.hoverLift(scale: 1.1))
                .help(L("Show this image"))
            } else {
                TypeBadge(type: item.type, size: 22)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(item.previewText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if item.type == .image {
                        let summary = item.imageSummary
                        if !summary.isEmpty {
                            Text(summary)
                            Text(verbatim: "·")
                        }
                    }
                    Text(item.createdAt.relativeFormatted)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.Metric.compactRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Theme.selection.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Metric.corner))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
