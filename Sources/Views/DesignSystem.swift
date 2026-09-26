import AppKit
import SwiftUI

/// Shared visual language.
///
/// The previous UI hard-coded ~200 point sizes and painted blue→purple gradients
/// on almost every surface, which reads as a phone game rather than a Mac
/// utility. Everything here is semantic: system text styles (so Dynamic Type and
/// accessibility settings work), system materials, and a single accent colour.
enum Theme {
    // MARK: Metrics

    /// Fixed metrics follow the text-size setting. A taller label in a row of
    /// fixed height is simply clipped, so the rows have to grow with it.
    enum Metric {
        @MainActor private static var scale: CGFloat { AppSettings.shared.textSize.metricScale }

        @MainActor static var rowHeight: CGFloat { (52 * scale).rounded() }
        @MainActor static var compactRowHeight: CGFloat { (40 * scale).rounded() }
        @MainActor static var iconSize: CGFloat { (26 * scale).rounded() }
        static let corner: CGFloat = 6
        static let gutter: CGFloat = 12
        static let sectionSpacing: CGFloat = 20
    }

    // MARK: Colours

    /// One accent: the user's choice, or the one the current theme was built
    /// around when they have not chosen.
    @MainActor
    static var accent: Color { ThemeManager.shared.accentColor }

    @MainActor private static var palette: ThemePalette { ThemeManager.shared.palette }

    /// Window and list background.
    @MainActor static var background: Color { palette.background }
    /// Rows, badges and wells.
    @MainActor static var secondaryBackground: Color { palette.surface }
    /// Floating surfaces: the palette panel, the menu bar popover.
    @MainActor static var elevated: Color { palette.elevated }
    @MainActor static var separator: Color { palette.separator }
    @MainActor static var selection: Color { accent.opacity(0.9) }

    /// System themes use AppKit's materials; a custom theme draws its own
    /// surfaces, because a material would blend in the desktop behind it and
    /// wash the palette out.
    @MainActor static var usesSystemMaterials: Bool { palette.usesSystemMaterials }

    /// Background for row `index` of a list.
    ///
    /// `alternatingRowBackgrounds()` paints AppKit's own white/grey pair over
    /// whatever the theme put behind it, which left custom themes with system
    /// coloured rows on a themed window. We alternate ourselves and let the
    /// system themes keep the native colours.
    /// AppKit's pair, fetched once. The colours it returns are dynamic, so a
    /// cached array still follows light and dark; what is avoided is crossing
    /// into AppKit for every row of every redraw.
    @MainActor private static let alternatingRowColors: [Color] =
        NSColor.alternatingContentBackgroundColors.map(Color.init(nsColor:))

    @MainActor
    static func rowBackground(_ index: Int) -> Color {
        if usesSystemMaterials {
            guard !alternatingRowColors.isEmpty else { return .clear }
            return alternatingRowColors[index % alternatingRowColors.count]
        }
        return index.isMultiple(of: 2) ? palette.background : palette.surface
    }
}

/// Fills a floating surface with a material under the system themes and with the
/// theme's own colour otherwise.
struct ElevatedSurface: ViewModifier {
    func body(content: Content) -> some View {
        if Theme.usesSystemMaterials {
            content.background(.regularMaterial)
        } else {
            content.background(Theme.elevated)
        }
    }
}

extension View {
    func elevatedSurface() -> some View { modifier(ElevatedSurface()) }

    /// Replaces a scrolling container's own backdrop with the theme background.
    @ViewBuilder
    func themedScrollBackground() -> some View {
        if Theme.usesSystemMaterials {
            self
        } else {
            self
                .scrollContentBackground(.hidden)
                .background(Theme.background)
        }
    }
}

/// Monochrome type badge. Content type is conveyed by symbol and label, not by
/// a colour that carries no meaning.
struct TypeBadge: View {
    let type: ContentType
    var size: CGFloat = Theme.Metric.iconSize

    var body: some View {
        Image(systemName: type.systemImage)
            .font(.system(size: size * 0.5))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Theme.secondaryBackground, in: RoundedRectangle(cornerRadius: Theme.Metric.corner))
    }
}

/// Keycap rendering used in hints and the shortcuts table.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.separator, lineWidth: 0.5)
            )
    }
}

struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            // The keycap is fixed and the label gives way, not the other way
            // round. Putting `fixedSize` on the label made it demand its full
            // width and crushed the caps into empty slivers, with "⌘1–9"
            // stacked one character per line.
            KeyCap(text: keys)
                .fixedSize()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
        }
    }
}

/// Picks the language CopyWell runs in.
///
/// The change lands immediately: `AppSettings` points `LanguageBundle` at the
/// chosen `.lproj` and moves `languageGeneration`, which every scene carries as
/// its `id`, so SwiftUI rebuilds and each string is read again.
struct LanguagePicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Picker(L("Language"), selection: Binding<String>(
            get: { settings.preferredLanguage ?? "" },
            set: { settings.preferredLanguage = $0.isEmpty ? nil : $0 }
        )) {
            // Names the language it currently resolves to, so the default is
            // an answer rather than a blank.
            Text(L("Same as the Mac (\(AppSettings.effectiveLanguageName))")).tag("")
            Divider()
            ForEach(AppSettings.availableLanguages, id: \.self) { code in
                Text(AppSettings.languageName(code)).tag(code)
            }
        }
    }
}

/// Empty states, consistent everywhere.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.hoverLink)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    /// Named accent colours offered in Settings.
    static func named(_ name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "indigo": return .indigo
        case "graphite": return .gray
        default: return .blue
        }
    }
}


/// Applies the current theme to the window this view ends up in.
///
/// A window cannot be themed before it exists, and SwiftUI gives no hook for
/// "my window is ready". Reaching it through a backing view is the reliable
/// way, and it re-applies whenever the theme changes.
private struct WindowThemeApplier: NSViewRepresentable {
    let themeID: String
    let accentID: String

    /// Applies the theme when the window appears, and only when something has
    /// actually changed.
    ///
    /// `viewDidMoveToWindow` is the hook for "my window exists now" and cannot
    /// be raced: the previous version waited a single turn of the run loop and
    /// gave up if the window was not there, which the lazily built Settings
    /// window never was — it kept the system appearance, so on a Mac set to
    /// Light a dark theme got a white tab bar around dark content.
    ///
    /// `updateNSView` runs on every SwiftUI update, and writing
    /// `window.appearance` causes another update, so applying unconditionally
    /// from there is a feedback loop with itself — a layout change such as
    /// collapsing the sidebar is enough to start it spinning. Remembering what
    /// was last applied breaks it: the repeat passes become no-ops.
    ///
    /// The repeat is still needed once, because SwiftUI configures the window
    /// after the view is attached and wipes the appearance we just set —
    /// measured: the applier ran with the right palette and the window still
    /// reported `appearance = nil` afterwards.
    final class Backing: NSView {
        var identity: String = ""
        private var appliedTo: ObjectIdentifier?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            appliedTo = nil
            // Synchronously, and only here. A window is not on screen yet when
            // its view tree is attached, so this is the one moment the theme can
            // land without the window being seen in the system appearance first
            // — which is what made Settings flash white on a dark theme.
            //
            // Deferring this was a guess at the sidebar crash, and the wrong
            // one: no frame of ours ever appeared in any of those stacks.
            if let window { ThemeManager.shared.apply(to: window) }
            applyTheme()
        }

        func applyTheme() {
            guard let window else { return }
            let target = ObjectIdentifier(window)
            let stamp = identity + "|" + String(describing: target)
            guard stamp != lastApplied || appliedTo != target else { return }
            lastApplied = stamp
            appliedTo = target

            // Never synchronously. Both callers run inside AppKit's layout
            // pass — `updateNSView` from the display cycle and
            // `viewDidMoveToWindow` when the hierarchy is rearranged, which is
            // exactly what collapsing the sidebar does. Setting the window's
            // appearance there asks it for a constraints update in the middle
            // of that cycle, and AppKit throws:
            //
            //   -[NSWindow _postWindowNeedsUpdateConstraints]
            //   -[NSView _informContainerThatSubviewsNeedUpdateConstraints]
            //   NSHostingView.setNeedsUpdate()
            //
            // with +[NSApplication _crashOnException:] on top. Four identical
            // reports, builds 12 and 13, every time the sidebar was hidden.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                ThemeManager.shared.apply(to: window)
                // SwiftUI configures the window after us and wipes what we set,
                // so once more after it has finished.
                DispatchQueue.main.async { [weak window] in
                    guard let window else { return }
                    ThemeManager.shared.apply(to: window)
                }
            }
        }

        private var lastApplied: String = ""
    }

    func makeNSView(context: Context) -> Backing {
        let view = Backing(frame: .zero)
        view.identity = themeID + "/" + accentID
        return view
    }

    func updateNSView(_ nsView: Backing, context: Context) {
        nsView.identity = themeID + "/" + accentID
        nsView.applyTheme()
    }
}

extension View {
    /// Keeps the enclosing window's appearance in step with the chosen theme.
    func themedWindow() -> some View {
        background(
            WindowThemeApplier(
                themeID: ThemeManager.shared.currentTheme.rawValue,
                accentID: ThemeManager.shared.accentColorName ?? "theme"
            )
            .frame(width: 0, height: 0)
        )
    }
}

// MARK: - Hover and press

/// Every control answers the pointer. These three styles cover the app's
/// borderless controls, so a button reads as a button before it is clicked:
///
/// * **Plate** — icon buttons and plain rows. A soft plate appears behind them
///   on hover, deepens while pressed, and the button sinks a touch.
/// * **Lift** — tiles, swatches, chips and cards that already have a shape of
///   their own. They rise slightly with a shadow, and settle when pressed.
/// * **Link** — text buttons. The accent lightens and underlines.
struct HoverPlateStyle: ButtonStyle {
    var plate: Color = .primary
    var rest: Double = 0
    var hover: Double = 0.09
    var press: Double = 0.17
    var padding: CGFloat = 4
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HoverPlate(configuration: configuration, style: self)
    }
}

private struct HoverPlate: View {
    let configuration: ButtonStyleConfiguration
    let style: HoverPlateStyle

    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        let amount = !isEnabled ? style.rest
            : configuration.isPressed ? style.press
            : hovered ? style.hover : style.rest
        configuration.label
            .padding(style.padding)
            .background(shape.fill(style.plate.opacity(amount)))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct HoverLiftStyle: ButtonStyle {
    var scale: CGFloat = 1.03

    func makeBody(configuration: Configuration) -> some View {
        HoverLift(configuration: configuration, scale: scale)
    }
}

private struct HoverLift: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat

    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let lifted = hovered && isEnabled && !configuration.isPressed
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : lifted ? scale : 1)
            .brightness(configuration.isPressed ? -0.04 : lifted ? 0.03 : 0)
            .shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: lifted ? 5 : 0, y: lifted ? 2 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct HoverLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLink(configuration: configuration)
    }
}

private struct HoverLink: View {
    let configuration: ButtonStyleConfiguration

    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .underline(hovered && isEnabled)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.55 : hovered ? 0.8 : 1)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

extension ButtonStyle where Self == HoverPlateStyle {
    static var hoverIcon: HoverPlateStyle { HoverPlateStyle() }

    static func hoverPlate(
        _ plate: Color = .primary, rest: Double = 0, hover: Double = 0.09, press: Double = 0.17,
        padding: CGFloat = 4, cornerRadius: CGFloat = 6
    ) -> HoverPlateStyle {
        HoverPlateStyle(plate: plate, rest: rest, hover: hover, press: press, padding: padding, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == HoverLiftStyle {
    static var hoverLift: HoverLiftStyle { HoverLiftStyle() }
    static func hoverLift(scale: CGFloat) -> HoverLiftStyle { HoverLiftStyle(scale: scale) }
}

extension ButtonStyle where Self == HoverLinkStyle {
    static var hoverLink: HoverLinkStyle { HoverLinkStyle() }
}

/// The same soft highlight the history rows have, for other lists of clips.
struct RowHover: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
