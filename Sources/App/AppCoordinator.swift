import AppKit
import Foundation
import Observation

/// Wires global shortcuts, capture and the palette together.
///
/// Lives for the lifetime of the process so hotkeys work whether or not a window
/// is open — a clipboard manager is useless if it only responds while focused.
@MainActor
@Observable
final class AppCoordinator {
    static let shared = AppCoordinator()

    private let monitor = ClipboardMonitor()
    private let store = ClipboardStore.shared
    private let shortcuts = GlobalShortcutsManager.shared

    private(set) var isPaused = false
    /// Non-nil when a shortcut could not be registered because another app owns it.
    ///
    /// Derived rather than stored: it was only recomputed at launch and after
    /// the recorder changed a binding, so clearing a shortcut or resetting them
    /// all left the warning standing over a problem that was already gone.
    var shortcutConflictMessage: String? {
        let conflicted = shortcuts.conflicts
        guard !conflicted.isEmpty else { return nil }
        let names = conflicted.map(\.title).sorted().joined(separator: ", ")
        return L("Another app already uses the shortcut for: \(names). Pick a different one in Settings ▸ Shortcuts.")
    }

    private init() {}

    func start() {
        StatisticsTracker.shared.resetDailyIfNeeded()
        PasteService.beginTrackingFrontmostApp()
        store.pruneOrphanedImages()
        store.backfillImageMetadata()

        monitor.onClipCaptured = { [weak self] clip in
            self?.store.insert(clip)
        }
        #if DEBUG
        // Demo mode shows invented content; recording the real clipboard on top
        // of it would both pollute the screenshots and capture private data.
        if !DemoContent.isActive { monitor.startMonitoring() }
        #else
        monitor.startMonitoring()
        #endif

        registerShortcuts()
        observeDayChanges()
        // Only lists Movies ▸ CopyWell, for the sidebar's count; it asks for
        // nothing and opens no device.
        RecordingLibrary.shared.refresh()
        SubscriptionManager.shared.start()
        SyncCoordinator.shared.start()
        AppSettings.shared.applyActivationPolicy()
    }

    func stop() {
        monitor.stopMonitoring()
        shortcuts.unregisterAll()
        SyncCoordinator.shared.stop()
    }

    /// A menu bar app runs for weeks. "Copied today" and "keep the last N
    /// days" were only brought up to date at launch, so both went stale after
    /// the first midnight.
    private func observeDayChanges() {
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                StatisticsTracker.shared.resetDailyIfNeeded()
                ClipboardStore.shared.enforceLimits()
            }
        }
    }

    // MARK: - Shortcuts

    private func registerShortcuts() {
        shortcuts.setHandler(for: .quickPaste) { Self.unlocked { QuickPastePanel.shared.toggle() } }
        shortcuts.setHandler(for: .pastePrevious) { [weak self] in Self.unlocked { self?.pastePrevious() } }
        shortcuts.setHandler(for: .pastePlainText) { [weak self] in Self.unlocked { self?.pastePlainText() } }
        shortcuts.setHandler(for: .pinLast) { [weak self] in Self.unlocked { self?.pinLast() } }
        shortcuts.setHandler(for: .togglePause) { [weak self] in Self.unlocked { self?.togglePause() } }
        shortcuts.setHandler(for: .pasteStackNext) { [weak self] in Self.unlocked { self?.pasteStackNext() } }
        shortcuts.setHandler(for: .captureScreenshot) { Self.unlocked { ScreenshotController.start() } }
        shortcuts.setHandler(for: .recordScreen) { Self.unlocked { ScreenRecorder.shared.toggle() } }

        shortcuts.registerAll()
        updateConflictMessage()
    }

    /// Runs `action` only while the app is unlocked. A shortcut that silently
    /// does nothing reads as a broken app, so the locked case opens the window
    /// with the subscription wall instead.
    static func unlocked(_ action: () -> Void) {
        guard SubscriptionManager.shared.isLocked else {
            action()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    /// Kept for callers that used to have to ask; the message is now derived.
    func updateConflictMessage() {}

    // MARK: - Actions

    func togglePause() {
        isPaused.toggle()
        monitor.setPaused(isPaused)
    }

    /// Pastes the clip before the current one, so ⇧⌘V flips between the last two.
    private func pastePrevious() {
        guard store.items.count > 1 else { return }
        paste(store.items[1], plainText: false)
    }

    private func pastePlainText() {
        guard let item = store.items.first else { return }
        paste(item, plainText: true)
    }

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        guard let content = item.pasteContent else { return }
        PasteService.rememberFrontmostApp()
        store.recordUse(item)
        StatisticsTracker.shared.recordPaste()
        PasteService.deliver(content, plainText: plainText)
    }

    private func pinLast() {
        guard let item = store.items.first else { return }
        if !item.isFavorite { store.toggleFavorite(item) }
    }

    private func pasteStackNext() {
        guard SubscriptionManager.shared.requestAccess(for: .pasteStack) else { return }
        guard let item = PasteStackManager.shared.pasteNext() else { return }
        paste(item, plainText: false)
    }

    /// Opens the Settings window from anywhere.
    ///
    /// The menu bar popover used to call SwiftUI's `openSettings` action the
    /// moment it dismissed itself, and nothing happened: the popover is still
    /// being torn down on that turn of the run loop, and the request goes
    /// nowhere. Activating first matters too — an app with no active window
    /// opens Settings behind whatever the user was looking at, which reads as a
    /// dead button just the same.
    func openSettingsWindow() {
        // Activating has to happen first and take effect before the action is
        // sent: `sendAction` walks the responder chain, and an inactive app has
        // nobody on it to answer, so the click did nothing at all.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            // SwiftUI's `Settings` scene installs its menu item with a private
            // action and target of its own — the item's action is `menuAction:`,
            // not `showSettingsWindow:` — so sending the documented selector
            // down the responder chain reaches nobody and the click does
            // nothing. Performing the menu item is what actually opens it.
            //
            // The item is found by its ⌘, key equivalent rather than by title,
            // which is the same in every language we ship.
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
                  let index = appMenu.items.firstIndex(where: {
                      $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
                  })
            else { return }
            appMenu.performActionForItem(at: index)
        }
    }

    /// Reopens the first-run guide.
    ///
    /// The guide lives in the main window, so it has to be open and in front
    /// before the request is posted — otherwise nothing is listening and the
    /// menu item appears to do nothing.
    func showSetupGuide() {
        openMainWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .copyWellRequestSetupWizard, object: nil)
        }
    }

    // MARK: - Windows

    func openMainWindow() {
        // Both branches of the old ternary here were `.regular`, so every time a
        // window was opened the Dock icon came back and "Show icon in the Dock"
        // could never be turned off. The setting already knows the right policy;
        // an accessory app shows windows perfectly well, it simply has no Dock
        // tile, so there is nothing to override.
        AppSettings.shared.applyActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window is NSPanel == false {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
