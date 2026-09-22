#if DEBUG
import AppKit
import SwiftUI

/// Renders the app's real windows to PNG files for the App Store listing.
///
/// `cacheDisplay(in:to:)` draws a window's own view hierarchy from inside the
/// process. Unlike `ImageRenderer` it draws AppKit-backed views — the clip
/// list, the search field, materials — which is most of what these screens are,
/// and unlike a screen capture it needs no Screen Recording permission and does
/// not care which Space anything is on. Windows are placed far off-screen so
/// nothing flashes on the display while this runs.
@MainActor
enum ScreenshotRenderer {
    static var isActive: Bool { CommandLine.arguments.contains("--render-screenshots") }

    /// Prints the real window's geometry.
    ///
    /// A toolbar overlapping the content is invisible to the offscreen renderer,
    /// which draws views without any window chrome. This asks the running window
    /// what it actually looks like.
    static var isDiagnosing: Bool { CommandLine.arguments.contains("--diagnose-layout") }

    /// Opens Settings the way the menu bar button does and reports the result.
    static var isDiagnosingSettings: Bool { CommandLine.arguments.contains("--diagnose-settings") }

    /// Toggles the sidebar and reports whether the main thread kept running.
    static var isDiagnosingSidebar: Bool { CommandLine.arguments.contains("--diagnose-sidebar") }

    /// Reports which localisation the app actually launched in.
    static var isDiagnosingLanguage: Bool { CommandLine.arguments.contains("--diagnose-language") }

    /// Proves the language changes while the app runs.
    ///
    /// One window, one hosting view, built once. The language is then changed
    /// under it and the pixels are taken again. Rendering each language into a
    /// fresh window would have proved nothing — the question is whether an
    /// interface already on screen follows.
    static func diagnoseLanguage() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let settings = AppSettings.shared
                // Everything this diagnostic touches is a real preference of
                // the person running it, written straight to their defaults.
                // Noted first and put back before exiting — a diagnostic that
                // leaves the app in Japanese on a light theme is a bug of its
                // own.
                let originalLanguage = settings.preferredLanguage
                let originalTheme = ThemeManager.shared.currentTheme
                let originalOnboarding = settings.hasCompletedOnboarding
                settings.hasCompletedOnboarding = true

                let root = AnyView(
                    LanguageProbe()
                        .environment(ClipboardStore.shared)
                        .environment(SubscriptionManager.shared)
                        .environment(settings)
                        .environment(AppCoordinator.shared)
                        .environment(\.controlActiveState, .key)
                )
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                let hosting = NSHostingView(rootView: root)
                window.contentView = hosting
                // Pinned to the light theme for the duration. Left alone, the
                // capture mixed the two: the window took the system appearance
                // while `Theme.*` kept answering from whichever theme is
                // stored, so a dark theme drew dark chips on a light window and
                // looked like a bug that was not there.
                ThemeManager.shared.currentTheme = .light
                window.appearance = NSAppearance(named: .aqua)
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                window.orderFront(nil)
                spin(for: 1.0)

                let identity = ObjectIdentifier(hosting)
                let directory = outputDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory())
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                for code in ["en", "ru", "ja", "ar"] {
                    settings.preferredLanguage = code
                    spin(for: 0.8)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    spin(for: 0.3)
                    print("\(code): generation=\(settings.languageGeneration) " +
                          "bundle=\((LanguageBundle.current.bundlePath as NSString).lastPathComponent) " +
                          "sample=\(L("Choose a language")) / \(L("Copy"))")
                    guard let content = window.contentView,
                          let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
                    rep.size = content.bounds.size
                    content.cacheDisplay(in: content.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        let url = directory.appendingPathComponent("language-\(code).png")
                        try? png.write(to: url)
                        print("  wrote \(url.lastPathComponent)")
                    }
                }

                print("same hosting view throughout: \(identity == ObjectIdentifier(window.contentView!))")

                settings.preferredLanguage = originalLanguage
                ThemeManager.shared.currentTheme = originalTheme
                settings.hasCompletedOnboarding = originalOnboarding
                print("restored: language=\(originalLanguage ?? "system") theme=\(originalTheme.rawValue)")
                exit(0)
            }
        }
    }

    /// The wizard, with the picker that drives it, so a screenshot shows both
    /// the choice and what the choice did.
    private struct LanguageProbe: View {
        @Environment(AppSettings.self) private var settings

        var body: some View {
            VStack(spacing: 0) {
                SetupWizard(onFinish: {})
            }
            .frame(width: 660, height: 620)
            .id(settings.languageGeneration)
        }
    }

    /// Tries to read a file by path, the way the Finder extension's "Save to
    /// CopyWell" makes the app do. Answers whether the sandbox permits it.
    static var isDiagnosingFileRead: Bool { CommandLine.arguments.contains("--diagnose-fileread") }

    static func diagnoseFileRead() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                guard let i = CommandLine.arguments.firstIndex(of: "--diagnose-fileread"),
                      i + 1 < CommandLine.arguments.count else {
                    print("RESULT: no path given"); exit(2)
                }
                let path = CommandLine.arguments[i + 1]
                let url = URL(fileURLWithPath: path)
                print("path: \(path)")
                print("exists (FileManager): \(FileManager.default.fileExists(atPath: path))")
                print("isReadable: \(FileManager.default.isReadableFile(atPath: path))")
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    print("RESULT: read \(text.count) characters — the sandbox allows it")
                    exit(0)
                } catch {
                    print("RESULT: could not read — \(error)")
                    exit(1)
                }
            }
        }
    }

    /// Hammers the window with layout changes.
    ///
    /// The sidebar toggle crashes inside `_NSViewLayout`, so anything that
    /// forces repeated layout passes should hit the same window-mutated-during-
    /// layout exception.
    static var isDiagnosingRelayout: Bool { CommandLine.arguments.contains("--diagnose-relayout") }

    static func diagnoseRelayout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
                    print("RESULT: no window"); exit(2)
                }
                NSApp.activate(ignoringOtherApps: true)
                let base = window.frame
                var n = 0
                let timer = Timer(timeInterval: 0.05, repeats: true) { t in
                    MainActor.assumeIsolated {
                        n += 1
                        var f = base
                        f.size.width = base.width + CGFloat((n % 12) * 30)
                        f.size.height = base.height + CGFloat((n % 7) * 25)
                        window.setFrame(f, display: true, animate: false)
                        window.contentView?.layoutSubtreeIfNeeded()
                        ThemeManager.shared.applyStoredTheme()
                        if n >= 120 {
                            t.invalidate()
                            print("RESULT: survived \(n) layout passes")
                            exit(0)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    /// Walks the palette's real window looking for whatever draws the hairline
    /// around it: a layer border, a frame view, the window's own edge.
    static var isDiagnosingPalette: Bool { CommandLine.arguments.contains("--diagnose-palette") }

    static func diagnosePalette() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                QuickPastePanel.shared.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated {
                        guard let panel = NSApp.windows.first(where: {
                            $0.isVisible && String(describing: type(of: $0)).contains("Panel")
                                && $0.frame.width > 300
                        }) else { print("RESULT: palette window not found"); exit(2) }

                        print("window \(type(of: panel)) opaque=\(panel.isOpaque) " +
                              "shadow=\(panel.hasShadow) style=\(panel.styleMask.rawValue) " +
                              "bg=\(panel.backgroundColor.description)")

                        func walk(_ v: NSView, _ d: Int) {
                            let pad = String(repeating: "  ", count: d)
                            let l = v.layer
                            let bw = l?.borderWidth ?? 0
                            let notable = bw > 0 || (l?.cornerRadius ?? 0) > 0 || l?.mask != nil
                                || l?.shadowOpacity ?? 0 > 0
                            if notable || d < 3 {
                                print("\(pad)\(type(of: v)) frame=\(Int(v.frame.width))x\(Int(v.frame.height)) " +
                                      "border=\(bw) radius=\(l?.cornerRadius ?? 0) " +
                                      "masks=\(l?.masksToBounds ?? false) " +
                                      "shadowOpacity=\(l?.shadowOpacity ?? 0) " +
                                      "borderColor=\(l?.borderColor.map { String(describing: $0) } ?? "nil")")
                            }
                            for sub in v.subviews { walk(sub, d + 1) }
                        }
                        if let frameView = panel.contentView?.superview {
                            print("--- from the frame view down ---")
                            walk(frameView, 0)
                        }
                        exit(0)
                    }
                }
            }
        }
    }

    /// Closes the main window, then waits to see whether launching the app
    /// again brings it back — the only way back a reviewer has if the menu bar
    /// icon is hidden under the notch of a crowded MacBook menu bar.
    static var isDiagnosingReopen: Bool { CommandLine.arguments.contains("--diagnose-reopen") }

    static func diagnoseReopen() {
        func report(_ text: String) {
            print(text)
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let url = docs.appendingPathComponent("reopen.txt")
                let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? (old + text + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        func mainVisible() -> Bool {
            NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !$0.isSheet }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                report("before close: main visible=\(mainVisible())")
                for w in NSApp.windows where w.canBecomeMain && !w.isSheet { w.close() }
                report("after close:  main visible=\(mainVisible())  policy=\(NSApp.activationPolicy().rawValue)")
                var seen = false
                let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if !seen && mainVisible() {
                            seen = true
                            report("REOPENED: the main window came back after a second launch")
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                    MainActor.assumeIsolated {
                        report(seen ? "RESULT: reopen works" : "RESULT: window did NOT come back")
                        exit(seen ? 0 : 1)
                    }
                }
            }
        }
    }

    /// Answers whether a first-time launch actually puts the setup guide on
    /// screen: whether a window opens at all when the app is a menu bar
    /// accessory, and whether the guide is presented over it.
    static var isDiagnosingFirstRun: Bool { CommandLine.arguments.contains("--diagnose-firstrun") }

    static func diagnoseFirstRun() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                let settings = AppSettings.shared
                print("hasCompletedOnboarding: \(settings.hasCompletedOnboarding)")
                let env = ProcessInfo.processInfo.environment
                print("XPC_SERVICE_NAME: \(env["XPC_SERVICE_NAME"] ?? "(нет)")")
                print("app active: \(NSApp.isActive)  frontmost: " +
                      "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
                print("showInDock: \(settings.showInDock)  policy: \(NSApp.activationPolicy().rawValue)")
                let visible = NSApp.windows.filter(\.isVisible)
                for w in visible {
                    print("  window '\(w.title)' sheet=\(w.isSheet) size=\(Int(w.frame.width))x\(Int(w.frame.height))")
                }
                let sheet = visible.contains(where: \.isSheet)
                let main = visible.contains { $0.canBecomeMain && !$0.isSheet }
                let line = "RESULT: main window \(main ? "opened" : "did NOT open"), " +
                    "setup guide \(sheet ? "is on screen" : "is NOT on screen")"
                print(line)
                // Launched through Finder there is no terminal to print to, so
                // the answer goes somewhere it can be read afterwards.
                let report = """
                XPC_SERVICE_NAME=\(env["XPC_SERVICE_NAME"] ?? "(нет)")
                active=\(NSApp.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
                policy=\(NSApp.activationPolicy().rawValue)
                mainWindowOnScreen=\(NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }?.isOnActiveSpace ?? false)
                \(line)
                """
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? report.write(to: docs.appendingPathComponent("firstrun.txt"),
                                      atomically: true, encoding: .utf8)
                }
                exit(main && (sheet || settings.hasCompletedOnboarding) ? 0 : 1)
            }
        }
    }

    /// Reports which toolbar items survive a narrow window.
    ///
    /// A toolbar short of room sweeps its trailing items into the » overflow
    /// menu, and the sidebar toggle — the one button whose job is to make room
    /// — went first. This measures it rather than trusting the eye: it squeezes
    /// the window to its minimum and prints what is still on show.
    static var isDiagnosingToolbar: Bool { CommandLine.arguments.contains("--diagnose-toolbar") }

    static func diagnoseToolbar() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
                      let toolbar = window.toolbar else {
                    print("RESULT: no window with a toolbar"); exit(2)
                }

                func report(_ label: String) {
                    let all = toolbar.items.map(\.itemIdentifier.rawValue)
                    let shown = toolbar.visibleItems?.map(\.itemIdentifier.rawValue) ?? []
                    let hidden = all.filter { !shown.contains($0) }
                    print("\(label) — window \(Int(window.frame.width))pt " +
                          "title=\(window.titleVisibility == .hidden ? "hidden" : "visible \u{27}\(window.title)\u{27}")")
                    print("   visible : \(shown.joined(separator: ", "))")
                    print("   overflow: \(hidden.isEmpty ? "none" : hidden.joined(separator: ", "))")
                    let sidebarHidden = hidden.contains { $0.localizedCaseInsensitiveContains("sidebar") }
                    print("   sidebar button in overflow: \(sidebarHidden)")
                }

                var frame = window.frame
                frame.size = NSSize(width: 1400, height: 800)
                window.setFrame(frame, display: true)
                spin(for: 0.8)
                report("wide")

                // The narrowest the window can go: `minWidth` on the content.
                frame.size = NSSize(width: 200, height: 800)
                window.setFrame(frame, display: true)
                spin(for: 1.0)
                report("as narrow as it goes")
                exit(0)
            }
        }
    }

    /// Clicks the real sidebar toggle. It is a SwiftUI-managed toolbar item
    /// with no action of its own, so the button has to be found and pressed.
    @MainActor
    private static func clickSidebarToggle() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
              let item = window.toolbar?.items.first(where: {
                  $0.itemIdentifier.rawValue.contains("toggleSidebar")
              })
        else { print("  (no sidebar toggle found)"); return }

        func button(in view: NSView) -> NSButton? {
            if let b = view as? NSButton { return b }
            for sub in view.subviews { if let b = button(in: sub) { return b } }
            return nil
        }
        if let view = item.view, let b = button(in: view) {
            b.performClick(nil)
            return
        }
        // SwiftUI items expose no `view`; the button lives in the titlebar.
        if let themeFrame = window.contentView?.superview {
            for sub in themeFrame.subviews where sub.className.contains("Titlebar") || sub.className.contains("Toolbar") {
                if let b = button(in: sub) { b.performClick(nil); return }
            }
        }
        print("  (sidebar toggle button not reachable)")
    }

    static func diagnoseSidebar() {
        // A repeating tick on the main queue. If the main thread blocks, the
        // gap between ticks grows, which is what a hang looks like from inside.
        final class Watch: @unchecked Sendable {
            var last = Date()
            var worst: TimeInterval = 0
        }
        let watch = Watch()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            let now = Date()
            watch.worst = max(watch.worst, now.timeIntervalSince(watch.last))
            watch.last = now
        }
        RunLoop.main.add(timer, forMode: .common)

        func step(_ name: String, after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    watch.last = Date()
                    work()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        MainActor.assumeIsolated {
                            var widths: [String] = []
                            func find(_ v: NSView) {
                                if let split = v as? NSSplitView {
                                    widths.append(split.arrangedSubviews.map { "\(Int($0.bounds.width))" }.joined(separator: "|"))
                                }
                                for sub in v.subviews { find(sub) }
                            }
                            if let content = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible })?.contentView {
                                find(content)
                            }
                            print("\(name): columns=[\(widths.joined(separator: " , "))] worstGap=\(String(format: "%.2f", watch.worst))s")
                        }
                    }
                }
            }
        }

        step("launch", after: 3) {
            NSApp.activate(ignoringOtherApps: true)
            watch.worst = 0
            if let tb = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible })?.toolbar {
                for item in tb.items {
                    let sel = item.action.map { NSStringFromSelector($0) } ?? "nil"
                    print("  TOOLBAR id=\(item.itemIdentifier.rawValue) action=\(sel) target=\(String(describing: item.target)) label='\(item.label)'")
                }
            }
        }
        func toggle() {
            NotificationCenter.default.post(name: .copyWellDebugToggleSidebar, object: nil)
        }
        step("hide sidebar", after: 4) { toggle() }
        step("show sidebar", after: 7) { toggle() }
        step("hide again", after: 10) { toggle() }
        step("show again", after: 13) { toggle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 17) {
            MainActor.assumeIsolated {
                let ok = watch.worst < 1.0
                print("RESULT: worst main-thread gap \(String(format: "%.2f", watch.worst))s — \(ok ? "responsive" : "HUNG")")
                exit(ok ? 0 : 1)
            }
        }
    }

    static func diagnoseSettings() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                print("theme=\(ThemeManager.shared.currentTheme.rawValue) wants=\(ThemeManager.shared.palette.appearance?.rawValue ?? "system")")
                let before = NSApp.windows.filter(\.isVisible)
                for w in before {
                    print("  before: '\(w.title)' appearance=\(w.appearance?.name.rawValue ?? "nil (system)")")
                }
                AppCoordinator.shared.openSettingsWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated {
                        let after = NSApp.windows.filter(\.isVisible)
                        for w in after {
                            print("  after:  '\(w.title)' appearance=\(w.appearance?.name.rawValue ?? "nil (system)")")
                        }
                        let opened = after.count > before.count
                        let wanted = ThemeManager.shared.palette.appearance?.rawValue
                        let themed = after
                            .filter { $0.level == .normal }
                            .allSatisfy { $0.appearance?.name.rawValue == wanted }
                        print(opened ? "RESULT: settings window opened" : "RESULT: settings did NOT open")
                        print(themed ? "RESULT: every ordinary window carries the theme appearance"
                                     : "RESULT: some window is NOT themed")
                        exit(opened && themed ? 0 : 1)
                    }
                }
            }
        }
    }

    static func diagnose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.canBecomeMain && window.isVisible {
                    print("window            frame            \(window.frame)")
                    print("window            contentLayoutRect \(window.contentLayoutRect)")
                    print("window            styleMask         \(window.styleMask.rawValue)")
                    print("window            titlebarAppears   \(window.titlebarAppearsTransparent)")
                    if let content = window.contentView {
                        print("contentView       bounds            \(content.bounds)")
                        print("contentView       safeAreaInsets    \(content.safeAreaInsets)")
                        let underlap = content.bounds.height - window.contentLayoutRect.height
                        print("=> content extends \(underlap) pt beyond the layout rect")
                        print("=> safe area top is \(content.safeAreaInsets.top) pt")
                    }
                    if let toolbar = window.toolbar {
                        print("toolbar           visible           \(toolbar.isVisible)")
                    }
                    // Anything drawn in the top 60 points of the window is either
                    // the toolbar or something hiding underneath it.
                    if let content = window.contentView {
                        print("--- scroll views in the detail column ---")
                        func scrolls(_ view: NSView) {
                            if let sv = view as? NSScrollView {
                                let f = sv.convert(sv.bounds, to: nil)
                                let top = content.bounds.height - f.maxY
                                print("  \(type(of: sv)) top=\(Int(top)) h=\(Int(sv.bounds.height)) x=\(Int(f.minX)) inset.top=\(sv.contentInsets.top) auto=\(sv.automaticallyAdjustsContentInsets)")
                            }
                            for sub in view.subviews { scrolls(sub) }
                        }
                        scrolls(content)
                        print("--- views intersecting the top 260 pt ---")
                        func walk(_ view: NSView, depth: Int) {
                            let inWindow = view.convert(view.bounds, to: nil)
                            let topOfWindow = content.bounds.height - inWindow.maxY
                            if topOfWindow < 260, view.bounds.height > 8, view.bounds.width > 40 {
                                let pad = String(repeating: "  ", count: depth)
                                print("\(pad)\(type(of: view)) top=\(Int(topOfWindow)) h=\(Int(view.bounds.height)) w=\(Int(view.bounds.width)) x=\(Int(inWindow.minX))")
                            }
                            guard depth < 12 else { return }
                            for sub in view.subviews { walk(sub, depth: depth + 1) }
                        }
                        walk(content, depth: 0)
                    }
                    break
                }
                exit(0)
            }
        }
    }

    private static var outputDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Screenshots", isDirectory: true)
    }

    static func run() {
        guard let directory = outputDirectory else { exit(2) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Store screenshots belong to a store locale, not to whoever is running
        // the renderer. Without this the shots came out in whatever language
        // the Mac happened to be set to.
        let language = CommandLine.arguments.firstIndex(of: "--language")
            .map { $0 + 1 }
            .flatMap { $0 < CommandLine.arguments.count ? CommandLine.arguments[$0] : nil }
            ?? "en"
        LanguageBundle.use(language)
        print("language: \(language)")

        let store = ClipboardStore.shared
        let subscriptions = SubscriptionManager.shared
        let locked = CommandLine.arguments.contains("--locked")
        subscriptions.simulatedPro = !locked
        subscriptions.forcedLock = locked
        let settings = AppSettings.shared
        // Put back before exiting. This is a real preference in the real
        // defaults, shared with every other copy of CopyWell on this Mac
        // because they all carry the same bundle id — leaving it set is how a
        // TestFlight install came up with no setup guide.
        let originalOnboarding = settings.hasCompletedOnboarding
        settings.hasCompletedOnboarding = true
        defer { settings.hasCompletedOnboarding = originalOnboarding }
        let coordinator = AppCoordinator.shared

        func dressed<V: View>(_ view: V) -> AnyView {
            AnyView(
                view
                    .environment(store)
                    .environment(subscriptions)
                    .environment(settings)
                    .environment(coordinator)
                    .tint(ThemeManager.shared.accentColor)
                    // Off-screen windows never become key, and SwiftUI would
                    // draw every label in its dimmed inactive state.
                    .environment(\.controlActiveState, .key)
            )
        }

        // The whole window in one piece, at exactly the 2880×1800 the store
        // asks for once the Retina backing is counted.
        //
        // This only became possible when `NavigationSplitView` went. Its
        // sidebar sat inside a visual-effect view, which `cacheDisplay` draws
        // as blank white, and that is why the two panes below are captured
        // separately and glued together by the composer. A plain HStack draws.
        let shots: [(String, CGSize, Bool, AnyView)] = [
            ("main-window", CGSize(width: 1440, height: 900), true, dressed(MainView())),
            ("sidebar", CGSize(width: 232, height: 700), false,
             dressed(SidebarView(selection: .constant(.history)).background(Theme.secondaryBackground))),
            ("list", CGSize(width: 948, height: 700), false,
             dressed(ClipboardListView(items: store.items, searchText: "", typeFilter: .constant(nil))
                .background(Theme.background))),
            ("palette", CGSize(width: 460, height: 540), false,
             dressed(QuickPasteView(onSelect: { _, _ in }, onDismiss: {}).background(Theme.background))),
            ("menubar", CGSize(width: 340, height: 460), false,
             dressed(MenuBarContentView().background(Theme.background))),
            ("statistics", CGSize(width: 980, height: 660), true,
             dressed(StatisticsView().background(Theme.background))),
            ("wizard", CGSize(width: 660, height: 600), false, dressed(SetupWizard(onFinish: {}))),
            ("paywall", CGSize(width: 460, height: 660), false, dressed(PaywallView())),
            ("wall", CGSize(width: 900, height: 620), false, dressed(SubscriptionWallView())),
            ("appearance", CGSize(width: 560, height: 420), false,
             dressed(AppearanceSettings().background(Theme.background))),
            // The whole window, tab bar and all: the panes on their own looked
            // right while the chrome around them did not.
            ("settings-window", CGSize(width: 560, height: 620), true,
             dressed(SettingsView())),
            ("settings-general", CGSize(width: 560, height: 560), false,
             dressed(GeneralSettings().background(Theme.background))),
            ("settings-privacy", CGSize(width: 560, height: 520), false,
             dressed(PrivacySettings().background(Theme.background))),
            // Sized to nothing on purpose: `.zero` means "ask the view how tall
            // it wants to be", which is what MenuBarExtra does. Forcing a size
            // here is exactly what hid the popover's footer being pushed out.
            ("menubar-natural", .zero, false,
             dressed(SubscriptionGate { MenuBarContentView() }.frame(minWidth: 320, minHeight: 280))),
        ]

        // `--all-themes` renders every theme, which is how a theme that only
        // half-applies gets noticed: the custom palettes are the ones where a
        // stray system colour shows up.
        let everyTheme = CommandLine.arguments.contains("--all-themes")
        let passes: [(AppTheme, String, NSAppearance.Name?)] = everyTheme
            ? AppTheme.allCases.map { ($0, $0.rawValue, $0.palette.appearance) }
            : [(AppTheme.light, "light", NSAppearance.Name.aqua),
               (AppTheme.dark, "dark", NSAppearance.Name.darkAqua)]

        for (theme, name, look) in passes {
            ThemeManager.shared.currentTheme = theme
            ThemeManager.shared.applyStoredTheme()
            let appearance = look.flatMap { NSAppearance(named: $0) }
            for (key, size, titled, view) in shots {
                capture(view, size: size, titled: titled, appearance: appearance,
                        to: directory.appendingPathComponent("\(key)-\(name).png"))
            }
        }

        print("rendered to \(directory.path)")
        // `defer` never runs before `exit`, so the restore is explicit.
        settings.hasCompletedOnboarding = originalOnboarding
        print("restored: hasCompletedOnboarding=\(originalOnboarding)")
        exit(0)
    }

    private static func capture(_ view: AnyView, size: CGSize, titled: Bool, appearance: NSAppearance?, to url: URL) {
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .miniaturizable, .fullSizeContentView]
            : [.borderless]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.appearance = appearance
        window.title = "CopyWell"
        let resolved = size == .zero ? hosting.fittingSize : size
        window.setContentSize(resolved)
        // Far off the left edge of any real display, so the user never sees it.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)

        // Let SwiftUI lay out, and let any asynchronous work the views kick off
        // on appear settle before the pixels are taken.
        spin(for: 1.5)
        window.contentView?.layoutSubtreeIfNeeded()
        spin(for: 0.6)
        window.displayIfNeeded()

        guard let content = window.contentView else { return }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        rep.size = bounds.size
        content.cacheDisplay(in: bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            print("  \(url.lastPathComponent) \(rep.pixelsWide)×\(rep.pixelsHigh)")
        } catch {
            FileHandle.standardError.write(Data("could not write \(url.path): \(error)\n".utf8))
        }
        window.orderOut(nil)
    }

    private static func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
#endif
