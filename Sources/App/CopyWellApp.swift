import AppKit
import SwiftUI

@main
struct CopyWellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var store = ClipboardStore.shared
    @State private var coordinator = AppCoordinator.shared
    @State private var settings = AppSettings.shared
    @State private var subscriptions = SubscriptionManager.shared
    @State private var recorder = ScreenRecorder.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            SubscriptionGate { MainView() }
                .environment(store)
                .environment(coordinator)
                .environment(settings)
                .environment(subscriptions)
                .tint(ThemeManager.shared.accentColor)
                .dynamicTypeSize(settings.textSize.dynamicTypeSize)
                // Rebuilds the whole tree when the language changes. Every
                // string is read inside a `body`, so re-running them is what
                // translates the interface on the spot.
                .id(settings.languageGeneration)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 980, height: 640)
        .commands { CopyWellCommands() }

        MenuBarExtra("CopyWell", systemImage: menuBarSymbol, isInserted: menuBarBinding) {
            // No frame here. `MenuBarContentView` states its own width and
            // computes its own height; an outer minHeight fought that and cut
            // the footer — with it, the "Open CopyWell" button — off the
            // bottom of the popover. The wall carries its own size instead.
            SubscriptionGate { MenuBarContentView() }
                .environment(store)
                .environment(coordinator)
                .environment(subscriptions)
                .tint(ThemeManager.shared.accentColor)
                .dynamicTypeSize(settings.textSize.dynamicTypeSize)
                .id(settings.languageGeneration)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(coordinator)
                .environment(settings)
                .environment(subscriptions)
                .tint(ThemeManager.shared.accentColor)
                .dynamicTypeSize(settings.textSize.dynamicTypeSize)
                .id(settings.languageGeneration)
        }
    }

    /// A recording in progress shows in the menu bar, where the icon is also
    /// the way back to the Stop button.
    private var menuBarSymbol: String {
        if recorder.isRecording { return "record.circle" }
        return coordinator.isPaused ? "clipboard" : "clipboard.fill"
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { settings.showInMenuBar },
            set: { settings.showInMenuBar = $0 }
        )
    }
}

/// App menu additions, so every shortcut is discoverable from the menu bar and
/// not only from a settings screen.
struct CopyWellCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("CopyWell Pro…")) { SubscriptionManager.shared.showingPaywall = true }
        }
        CommandGroup(replacing: .help) {
            Button(L("CopyWell Setup Guide")) {
                AppCoordinator.shared.showSetupGuide()
            }
            Divider()
            Link(L("Support"), destination: LegalLinks.support)
            Link(L("Privacy Policy"), destination: LegalLinks.privacyPolicy)
        }
        // Every item here goes through `unlocked`, which either runs the action
        // or brings the subscription wall forward. A menu item that quietly
        // does nothing reads as a broken app.
        CommandMenu(L("Clipboard")) {
            Button(L("Open Palette")) { AppCoordinator.unlocked { QuickPastePanel.shared.toggle() } }
                .keyboardShortcut("v", modifiers: [.option, .command])
            Button(L("Quick Look")) {
                AppCoordinator.unlocked {
                    NotificationCenter.default.post(name: .copyWellRequestPreviewSelection, object: nil)
                }
            }
            .keyboardShortcut("y", modifiers: .command)
            Divider()
            Button(AppCoordinator.shared.isPaused ? L("Resume Recording") : L("Pause Recording")) {
                AppCoordinator.unlocked { AppCoordinator.shared.togglePause() }
            }
            .keyboardShortcut("p", modifiers: [.control, .option])
            Divider()
            Button(L("Capture Area…")) {
                AppCoordinator.unlocked { ScreenshotController.start() }
            }
            Button(ScreenRecorder.shared.isRecording ? L("Stop Recording") : L("Record Screen…")) {
                AppCoordinator.unlocked { ScreenRecorder.shared.toggle() }
            }
            Divider()
            Button(L("Clear History…")) {
                AppCoordinator.unlocked {
                    NotificationCenter.default.post(name: .copyWellRequestClearHistory, object: nil)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Where an uncaught exception's description is written, so the next launch
    /// can say what happened. The crash reports carry the stack but not the
    /// reason, and the reason is the part that names the bug.
    static var exceptionLogURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CopyWell/last-exception.txt")
    }

    /// Survive an exception thrown by AppKit or SwiftUI during layout.
    ///
    /// Hiding the sidebar raises inside
    /// -[NSWindow _postWindowNeedsUpdateConstraints] while SwiftUI invalidates a
    /// hosting view in the window's own display cycle — five identical reports,
    /// builds 12 to 16, with no frame of ours anywhere in the stack. SwiftUI
    /// turns on NSApplicationCrashOnExceptions, which converts that into an
    /// immediate kill; AppKit's own behaviour is to log it and carry on, and
    /// carrying on leaves the user with a working app.
    ///
    /// This is a mitigation, not a fix: it is here because the fault is not
    /// reachable from our code. The handler records the reason so it can be.
    private func survivePlatformExceptions() {
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")
        NSSetUncaughtExceptionHandler { exception in
            let text = """
            \(Date())
            \(exception.name.rawValue)
            \(exception.reason ?? "no reason")

            \(exception.callStackSymbols.prefix(40).joined(separator: "\n"))
            """
            if let url = AppDelegate.exceptionLogURL {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            NSLog("CopyWell uncaught exception: %@ — %@", exception.name.rawValue, exception.reason ?? "")
        }
    }

    /// True while the screenshot renderer runs: it builds and captures its own
    /// off-screen windows, and raising the main one over them would land in the
    /// pictures. The diagnostics are deliberately *not* excluded — a diagnostic
    /// that watches a special case instead of the shipped behaviour is worth
    /// nothing.
    private static var isRunningADiagnostic: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--render-screenshots")
            || CommandLine.arguments.contains("--diagnose-capture")
            || CommandLine.arguments.contains("--diagnose-clicks")
            || CommandLine.arguments.contains("--diagnose-recording")
            || CommandLine.arguments.contains("--diagnose-screenshot-actions")
            || CommandLine.arguments.contains("--render-feature-shots")
        #else
        false
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        survivePlatformExceptions()
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()

        MainActor.assumeIsolated {
            AppCoordinator.shared.start()
            ThemeManager.shared.applyStoredTheme()
            #if DEBUG
            if ScreenshotRenderer.isActive { ScreenshotRenderer.run() }
            if ScreenshotRenderer.isDiagnosing { ScreenshotRenderer.diagnose() }
            if ScreenshotRenderer.isDiagnosingSettings { ScreenshotRenderer.diagnoseSettings() }
            if ScreenshotRenderer.isDiagnosingSidebar { ScreenshotRenderer.diagnoseSidebar() }
            if ScreenshotRenderer.isDiagnosingToolbar { ScreenshotRenderer.diagnoseToolbar() }
            if ScreenshotRenderer.isDiagnosingFirstRun { ScreenshotRenderer.diagnoseFirstRun() }
            if ScreenshotRenderer.isDiagnosingPalette { ScreenshotRenderer.diagnosePalette() }
            if ScreenshotRenderer.isDiagnosingReopen { ScreenshotRenderer.diagnoseReopen() }
            if ScreenshotRenderer.isDiagnosingRelayout { ScreenshotRenderer.diagnoseRelayout() }
            if ScreenshotRenderer.isDiagnosingFileRead { ScreenshotRenderer.diagnoseFileRead() }
            if ScreenshotRenderer.isDiagnosingLanguage { ScreenshotRenderer.diagnoseLanguage() }
            if CaptureDiagnostics.isActive { CaptureDiagnostics.run() }
            if CaptureDiagnostics.isShowingClicks { CaptureDiagnostics.showClicks() }
            if CaptureDiagnostics.isTestingRecording { CaptureDiagnostics.testRecording() }
            if CaptureDiagnostics.isTestingScreenshotActions { CaptureDiagnostics.testScreenshotActions() }
            if FeatureShots.isActive { FeatureShots.run() }
            #endif

            // An accessory app is not brought forward by the system when it
            // launches. Measured on a Finder launch: the window opens, but
            // `NSApp.isActive` comes back false and another app stays
            // frontmost, so the window sits behind everything and the launch
            // reads as "nothing happened".
            //
            // SwiftUI builds the WindowGroup's window after this method runs,
            // so the next turn of the run loop is the earliest the window
            // exists to be raised.
            if !Self.isRunningADiagnostic {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AppCoordinator.shared.openMainWindow() }
                }
            }
        }

        observeWindowPrivacy()
    }

    /// Handles `copywell://save?path=…` and `copywell://open` from the Finder
    /// extension. Paths arrive from a user's right-click on files they selected,
    /// which is what grants us access to them.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "copywell" else { continue }
            switch url.host {
            case "open":
                MainActor.assumeIsolated { AppCoordinator.shared.openMainWindow() }
            default:
                break
            }
        }
    }

    // `copywell://save?path=…` is gone. A sandboxed app may not read a file it
    // was only told the path of, and the code that handled it fell back to
    // storing the path as though it were the file's contents. The Finder
    // extension reads what the user selected and puts it on the pasteboard,
    // which is a route that exists and works.

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppCoordinator.shared.stop()
            ClipboardStore.shared.save()
        }
    }

    /// Keeping the app alive without windows is the point: the menu bar item and
    /// the global shortcuts must keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated { AppCoordinator.shared.openMainWindow() }
        }
        return true
    }

    // MARK: - Screen capture privacy

    private func observeWindowPrivacy() {
        applyWindowPrivacy()
        NotificationCenter.default.addObserver(
            forName: .copyWellWindowPrivacyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppDelegate.applyPrivacyToAllWindows() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppDelegate.applyPrivacyToAllWindows()
                // A window created after the theme was chosen still has AppKit's
                // default backdrop until it is told otherwise.
                ThemeManager.shared.applyStoredTheme()
            }
        }
    }

    private func applyWindowPrivacy() {
        MainActor.assumeIsolated { AppDelegate.applyPrivacyToAllWindows() }
    }

    /// When enabled, CopyWell's windows are excluded from screen recordings and
    /// screenshots — a clipboard manager shows exactly the things you do not want
    /// captured during a screen share.
    @MainActor
    static func applyPrivacyToAllWindows() {
        let hide = AppSettings.shared.hideFromScreenCapture
        // The camera bubble and the click and drawing layer are there to be
        // recorded; hiding them would make the settings that show them do
        // nothing.
        for window in NSApp.windows where !(window is RecordableWindow) {
            window.sharingType = hide ? .none : .readOnly
        }
    }
}

extension Notification.Name {
    static let copyWellRequestClearHistory = Notification.Name("copyWellRequestClearHistory")
    /// Menu-driven Quick Look: a menu item is both a reliable key handler and a
    /// discoverable one, unlike a hidden button holding a shortcut.
    static let copyWellRequestPreviewSelection = Notification.Name("copyWellRequestPreviewSelection")
    /// Reopens the first-run guide from Settings.
    static let copyWellRequestSetupWizard = Notification.Name("copyWellRequestSetupWizard")
    #if DEBUG
    /// Development only: drives the sidebar the way its toolbar button does,
    /// which is the only way to reproduce the crash it causes from a harness.
    static let copyWellDebugToggleSidebar = Notification.Name("copyWellDebugToggleSidebar")
    #endif
}
