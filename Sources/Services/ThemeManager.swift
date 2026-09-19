import AppKit
import Observation
import SwiftUI

/// A theme's colour tokens.
///
/// Each custom theme pins the system appearance it is built for, so system label
/// colours, controls and focus rings keep their correct contrast; only the
/// surfaces and the accent are ours. That is what keeps these themes readable
/// rather than a set of coloured backgrounds with unreadable text on top.
struct ThemePalette {
    /// `nil` follows the system setting.
    let appearance: NSAppearance.Name?
    /// Window and list background.
    let background: Color
    /// Rows, badges, wells.
    let surface: Color
    /// Floating surfaces: the palette panel and the menu bar popover.
    let elevated: Color
    let separator: Color
    /// The accent used when the user has not chosen one.
    let accent: Color
    /// Whether the app draws its own surfaces or defers to system materials.
    let usesSystemMaterials: Bool
}

@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var currentTheme: AppTheme = .system {
        didSet {
            persist()
            Task { @MainActor in self.applyStoredTheme() }
        }
    }

    /// `nil` means "whatever the theme suggests".
    var accentColorName: String? {
        didSet { persist() }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "app_theme"),
           let theme = AppTheme(rawValue: raw) {
            currentTheme = theme
        }
        accentColorName = UserDefaults.standard.string(forKey: "accent_color")
    }

    var palette: ThemePalette { currentTheme.palette }

    var accentColor: Color {
        if let accentColorName { return .named(accentColorName) }
        return palette.accent
    }

    /// The appearance the Mac itself is set to, regardless of our theme.
    @MainActor
    private static var systemAppearance: NSAppearance? {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?
            .lowercased().contains("dark") ?? false
        return NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    @MainActor
    func applyStoredTheme() {
        // On the application, so that every window is *born* themed.
        //
        // This used to be per-window, to keep the menu bar icon out of it: a
        // themed status item draws a pale chip behind the icon while every
        // other icon in the menu bar sits flat. But a window can only be themed
        // per-window after it exists, and the Settings window was visible
        // before that happened — it flashed white on a dark theme, whether the
        // work was done synchronously or deferred. Setting it here means there
        // is no moment when a window is on screen untheme.
        //
        // The status item keeps its old behaviour by being pinned to the Mac's
        // own appearance below, which is what it inherited before.
        NSApp.appearance = palette.appearance.map { NSAppearance(named: $0) } ?? nil

        applyToAllWindows()
        // Again on the next turn of the run loop. SwiftUI reconfigures its
        // windows after we touch them — opening the Settings window wiped the
        // appearance straight back off the main one, measured as darkAqua
        // before and nil after — and this lands after it has finished.
        DispatchQueue.main.async { [weak self] in
            self?.applyToAllWindows()
        }
    }

    @MainActor
    private func applyToAllWindows() {
        for window in NSApp.windows {
            if Self.isSystemOwned(window) {
                // Pinned, not left to inherit: the app's appearance is now the
                // theme's, and the menu bar is not ours to colour.
                let system = Self.systemAppearance
                if window.appearance?.name != system?.name { window.appearance = system }
            } else {
                apply(to: window)
            }
        }
    }

    /// Applies the theme to one window.
    ///
    /// Looping `NSApp.windows` misses a window that does not exist yet — the
    /// Settings scene builds its window after `onAppear` runs, so it kept the
    /// system appearance while every other window followed the theme.
    /// Writes only what differs.
    ///
    /// Assigning `appearance` or `backgroundColor` makes AppKit redraw and
    /// SwiftUI update, which comes straight back here; doing it unconditionally
    /// is a loop waiting for something to start it.
    @MainActor
    func apply(to window: NSWindow) {
        guard !Self.isSystemOwned(window) else { return }
        let palette = self.palette
        let appearance = palette.appearance.map { NSAppearance(named: $0) } ?? nil

        // A window that made itself transparent meant it. The palette is a
        // borderless panel with a clear background that rounds its own corners
        // in a layer; painting the theme colour behind that fills the corners
        // straight back in, and the seam between the square window colour and
        // the rounded content is the hairline that kept being reported around
        // the palette. Measured: the panel's backgroundColor came back as the
        // theme's own 0.051/0.051/0.059 despite being set to `.clear` when the
        // panel was built.
        if Self.managesOwnBackground(window) {
            window.appearance = appearance
            window.contentView?.appearance = appearance
            if window.backgroundColor != .clear { window.backgroundColor = .clear }
            return
        }

        let wantedBackground = palette.usesSystemMaterials ? nil : NSColor(palette.background)
        guard window.appearance?.name != appearance?.name
                || window.backgroundColor != wantedBackground
        else { return }
        window.appearance = appearance
        // The hosting view does not always pick the window's appearance up: the
        // chrome went dark while the SwiftUI content stayed light. Setting it on
        // the content view too makes the whole hierarchy agree.
        window.contentView?.appearance = appearance
        window.backgroundColor = wantedBackground
    }

    /// The status item's button is hosted in a window the system owns; theming
    /// it is both wrong and visible.
    private static func isSystemOwned(_ window: NSWindow) -> Bool {
        window.level == .statusBar || window.className.contains("NSStatusBar")
    }

    /// Windows that paint their own backdrop and must be left alone: borderless
    /// and non-opaque is how a floating panel says so.
    private static func managesOwnBackground(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.borderless) && !window.isOpaque
    }

    private func persist() {
        UserDefaults.standard.set(currentTheme.rawValue, forKey: "app_theme")
        if let accentColorName {
            UserDefaults.standard.set(accentColorName, forKey: "accent_color")
        } else {
            UserDefaults.standard.removeObject(forKey: "accent_color")
        }
    }

    static let accentOptions = ["blue", "purple", "indigo", "teal", "green", "orange", "red", "pink", "graphite"]
}

enum AppTheme: String, CaseIterable, Identifiable {
    /// Follows the macOS appearance setting.
    case system
    case light
    case dark
    /// Warm off-white, for long reading sessions.
    case paper
    /// Neutral grey; no colour cast at all.
    case graphite
    /// Cool blue-grey.
    case slate
    /// Near-black with a muted brass accent.
    case ink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        case .paper: return L("Paper")
        case .graphite: return L("Graphite")
        case .slate: return L("Slate")
        case .ink: return L("Ink")
        }
    }

    var summary: String {
        switch self {
        case .system: return L("Follows your macOS appearance setting.")
        case .light: return L("Always light.")
        case .dark: return L("Always dark.")
        case .paper: return L("Warm off-white, easier on the eyes in daylight.")
        case .graphite: return L("Neutral dark grey with no colour cast.")
        case .slate: return L("Cool blue-grey dark.")
        case .ink: return L("Near-black with a muted brass accent.")
        }
    }

    var isCustom: Bool {
        switch self {
        case .system, .light, .dark: return false
        default: return true
        }
    }

    var palette: ThemePalette {
        switch self {
        case .system:
            return .systemPalette(appearance: nil)
        case .light:
            return .systemPalette(appearance: .aqua)
        case .dark:
            return .systemPalette(appearance: .darkAqua)
        case .paper:
            return ThemePalette(
                appearance: .aqua,
                background: Color(hex: "F4F1EA"),
                surface: Color(hex: "FBF9F4"),
                elevated: Color(hex: "FDFCF8"),
                separator: Color(hex: "DED7C8"),
                accent: Color(hex: "3D5A80"),
                usesSystemMaterials: false
            )
        case .graphite:
            return ThemePalette(
                appearance: .darkAqua,
                background: Color(hex: "1B1B1D"),
                surface: Color(hex: "242426"),
                elevated: Color(hex: "2B2B2E"),
                separator: Color(hex: "3A3A3D"),
                accent: Color(hex: "9AA0A6"),
                usesSystemMaterials: false
            )
        case .slate:
            return ThemePalette(
                appearance: .darkAqua,
                background: Color(hex: "191E25"),
                surface: Color(hex: "212832"),
                elevated: Color(hex: "27303B"),
                separator: Color(hex: "343E4B"),
                accent: Color(hex: "6E93C8"),
                usesSystemMaterials: false
            )
        case .ink:
            return ThemePalette(
                appearance: .darkAqua,
                background: Color(hex: "0D0D0F"),
                surface: Color(hex: "161618"),
                elevated: Color(hex: "1C1C1F"),
                separator: Color(hex: "2A2A2E"),
                accent: Color(hex: "B99A63"),
                usesSystemMaterials: false
            )
        }
    }
}

private extension ThemePalette {
    /// Defers to AppKit's own colours, which already adapt to light and dark and
    /// to the user's accent and contrast settings.
    ///
    /// The colours are resolved against the theme's *own* appearance, not the
    /// one currently in effect. A dynamic `NSColor` asked for its value while
    /// the app is dark answers with its dark value, which made the Light
    /// preview in Settings render dark. `nil` — the System theme — stays
    /// dynamic on purpose, because following the Mac is what it means.
    static func systemPalette(appearance: NSAppearance.Name?) -> ThemePalette {
        ThemePalette(
            appearance: appearance,
            background: resolve(.windowBackgroundColor, in: appearance),
            surface: resolve(.controlBackgroundColor, in: appearance),
            elevated: resolve(.controlBackgroundColor, in: appearance),
            separator: resolve(.separatorColor, in: appearance),
            accent: resolve(.controlAccentColor, in: appearance),
            usesSystemMaterials: true
        )
    }

    static func resolve(_ color: NSColor, in name: NSAppearance.Name?) -> Color {
        guard let name, let appearance = NSAppearance(named: name) else {
            return Color(nsColor: color)
        }
        // `performAsCurrentDrawingAppearance` hands the closure back synchronously,
        // so a local box is enough and nothing escapes.
        final class Box: @unchecked Sendable {
            var value: NSColor
            init(_ value: NSColor) { self.value = value }
        }
        let box = Box(color)
        appearance.performAsCurrentDrawingAppearance {
            box.value = color.usingColorSpace(.sRGB) ?? color
        }
        return Color(nsColor: box.value)
    }
}
