import AppKit
import SwiftUI

/// Floating palette shown by ⌥⌘V.
///
/// It is a non-activating panel so the app the user is typing in stays frontmost
/// conceptually: we remember it and hand focus straight back when a clip is
/// chosen. A regular window would steal activation and there would be nothing
/// left to paste into.
@MainActor
final class QuickPastePanel: NSObject, NSWindowDelegate {
    static let shared = QuickPastePanel()

    private var panel: NSPanel?
    private var localMonitor: Any?
    /// True when the palette was opened while CopyWell itself was in front.
    private var openedFromOurApp = false
    /// When the palette last closed itself because it lost the keyboard.
    private var lastDismissalByFocusLoss: Date?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
            return
        }
        // Clicking the toolbar button makes the main window key, which takes
        // the keyboard off the palette, which closes it — all before this
        // handler runs. Without this the second click found the palette
        // already gone and opened it straight back up, so it never appeared to
        // close at all. A click that arrives on the heels of that dismissal is
        // the click that caused it.
        if let closed = lastDismissalByFocusLoss, Date().timeIntervalSince(closed) < 0.35 {
            lastDismissalByFocusLoss = nil
            return
        }
        show()
    }

    func show() {
        // Locked means locked: the palette is the whole product, so it does not
        // appear at all until a subscription is active.
        guard SubscriptionManager.shared.hasFullAccess else { return }
        openedFromOurApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == NSRunningApplication.current.processIdentifier
        PasteService.rememberFrontmostApp()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Guard against anything having resized the panel while it was hidden.
        if panel.frame.size != QuickPasteView.panelSize {
            panel.setContentSize(QuickPasteView.panelSize)
        }
        applyPrivacy(to: panel)
        position(panel)

        // Key, but without activating us. The panel is a `.nonactivatingPanel`
        // that overrides `canBecomeKey`, which is exactly how Spotlight takes
        // the keyboard while the app underneath stays active — and the whole
        // reason it is built that way.
        //
        // `NSApp.activate` used to follow this line and undid it: taking
        // activation deactivates the app being typed into, and that app drops
        // its text selection. The caret survives, the selection does not, so
        // pasting over selected text did nothing while pasting at a plain
        // insertion point worked.
        panel.makeKeyAndOrderFront(nil)
        installEscapeMonitor()
    }

    func hide() {
        removeEscapeMonitor()
        panel?.orderOut(nil)
        // Hand focus back to where the user came from — but only if that was
        // somewhere else. Opened from CopyWell's own window, activating the
        // previous app pushes that window behind everything, and with no Dock
        // tile there is nothing left to click to get it back.
        guard !openedFromOurApp else { return }
        PasteService.previousApp?.activate()
    }

    private func makePanel() -> NSPanel {
        // Borderless, so the palette's content fills the window edge to edge the
        // way Spotlight does — a titled panel leaves a dead strip along the top.
        let size = QuickPasteView.panelSize
        // Not `.resizable`: a resizable borderless panel re-fits itself to the
        // hosting view and collapses whenever SwiftUI re-measures.
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // A window is opaque by default, so a clear background still painted a
        // hard square edge around the rounded content — and the shadow traced
        // that square rather than the palette.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self

        let root = QuickPasteRoot(
            onSelect: { [weak self] item, plainText in
                self?.commit(item, plainText: plainText)
            },
            onDismiss: { [weak self] in self?.hide() }
        )

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        // AppKit rounds the corners, so the edge is a clean layer mask rather
        // than an antialiased SwiftUI clip with a grey seam along it.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.setContentSize(size)
        return panel
    }

    private func commit(_ item: ClipboardItem, plainText: Bool) {
        hide()
        guard let content = item.pasteContent else { return }
        ClipboardStore.shared.recordUse(item)
        StatisticsTracker.shared.recordPaste()
        PasteService.deliver(content, plainText: plainText)
    }

    /// Opens the palette under the mouse, kept fully on the active screen.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        if origin.y < visible.minY + 8 {
            origin.y = min(mouse.y + 12, visible.maxY - size.height - 8)
        }
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrameOrigin(origin)
    }

    /// Honours "Hide from screen capture" for the palette too — it shows the same
    /// clip contents the main window does.
    private func applyPrivacy(to panel: NSPanel) {
        panel.sharingType = AppSettings.shared.hideFromScreenCapture ? .none : .readOnly
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking away dismisses the palette, like Spotlight.
        lastDismissalByFocusLoss = Date()
        hide()
    }
}

/// A borderless panel refuses key status by default, which would leave the
/// search field untypable.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The palette's content, reading the settings inside a `body`.
///
/// The panel is built once and kept. Its tint, text size and language used to
/// be read when it was built, so changing any of them in Settings left the
/// palette as it was until CopyWell was quit.
private struct QuickPasteRoot: View {
    let onSelect: (ClipboardItem, Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        let settings = AppSettings.shared
        QuickPasteView(onSelect: onSelect, onDismiss: onDismiss)
            .environment(ClipboardStore.shared)
            .tint(ThemeManager.shared.accentColor)
            .dynamicTypeSize(settings.textSize.dynamicTypeSize)
            .id(settings.languageGeneration)
    }
}
