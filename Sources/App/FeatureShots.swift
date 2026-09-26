#if DEBUG
import AppKit
import SwiftUI

/// Development only: renders the App Store screenshots for the capture
/// features — screenshots with markup, screen recording, choosing what to
/// record, and the Recordings library — at 2880 × 1800.
///
/// The parts of CopyWell in them are CopyWell's own views: the capture overlay
/// with its marks and toolbars, the recording controls, the countdown, the
/// recording cards. Only the scene they sit on — a desktop with a made-up
/// dashboard, and the presenter in the camera bubble — is drawn here.
@MainActor
enum FeatureShots {
    static var isActive: Bool { CommandLine.arguments.contains("--render-feature-shots") }

    static let size = CGSize(width: 1440, height: 900)

    /// The words on the shots, by key, in the language being rendered and in
    /// English as the fallback. They come from docs/store/shots/<lang>.json,
    /// copied into the container's Documents/shot-strings before a run —
    /// the sandbox keeps the app out of the repository itself.
    nonisolated(unsafe) static var strings: [String: String] = [:]
    nonisolated(unsafe) static var english: [String: String] = [:]
    nonisolated(unsafe) static var language = "en"

    static var isRightToLeft: Bool { ["ar", "he", "ur"].contains(language) }

    private static func loadStrings() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shot-strings", isDirectory: true)
        func read(_ code: String) -> [String: String] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(code).json")),
                  let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return table
        }
        english = read("en")
        strings = read(language)
        print("strings: \(strings.count) for \(language), \(english.count) in English")
    }

    static func run() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { render() }
        }
    }

    private static func render() {
        language = CommandLine.arguments.firstIndex(of: "--language")
            .map { $0 + 1 }
            .flatMap { $0 < CommandLine.arguments.count ? CommandLine.arguments[$0] : nil } ?? "en"
        LanguageBundle.use(language)
        loadStrings()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshots/features/\(language)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The recording toolbar shows the switches as they are set; for the
        // pictures camera and voice are on. Put back afterwards.
        let settings = AppSettings.shared
        let saved = (settings.recordCamera, settings.recordMicrophone, settings.recordSystemAudio,
                     settings.recordShowsPointer, settings.recordShowsClicks)
        settings.recordCamera = true
        settings.recordMicrophone = true
        settings.recordSystemAudio = false
        settings.recordShowsPointer = true
        settings.recordShowsClicks = true
        ScreenRecorder.shared.marketingElapsed = 134
        defer {
            settings.recordCamera = saved.0
            settings.recordMicrophone = saved.1
            settings.recordSystemAudio = saved.2
            settings.recordShowsPointer = saved.3
            settings.recordShowsClicks = saved.4
            ScreenRecorder.shared.marketingElapsed = nil
        }

        let shots: [(String, AnyView)] = [
            ("feature-1-screenshots", AnyView(MarkupShot(overlay: markupOverlay()))),
            ("feature-2-recording", AnyView(RecordingShot())),
            ("feature-3-choose", AnyView(ChooseShot(bar: image(recordingBar(), size: recordingBarSize())))),
            ("feature-4-recordings", AnyView(LibraryShot(thumbnails: thumbnails()))),
        ]
        for (name, view) in shots {
            if let rep = bitmap(view, size: size) {
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
                print("wrote \(name).png \(rep.pixelsWide)×\(rep.pixelsHigh)")
            }
        }
        print("RESULT: done, files in \(directory.path)")
        exit(0)
    }

    // MARK: - Rendering

    static func bitmap<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -8000, y: -8000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    static func image<V: View>(_ view: V, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        if let rep = bitmap(view, size: size) { image.addRepresentation(rep) }
        return image
    }

    // MARK: - Shot 1: the overlay, marked up

    /// The desktop, photographed as the screenshot overlay would, then run
    /// through the overlay itself: a selection, and marks made the way a
    /// person makes them, by dragging.
    private static func markupOverlay() -> NSImage {
        guard let screen = bitmap(DesktopScene(), size: size)?.cgImage else { return NSImage() }
        let state = CaptureToolState()
        let view = CaptureOverlayView(frame: CGRect(origin: .zero, size: size), mode: .screenshot, snapshot: screen, state: state)
        let window = CaptureOverlayWindow(contentRect: CGRect(origin: CGPoint(x: -8000, y: -8000), size: size),
                                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.orderFrontRegardless()
        state.onChange = { view.toolDidChange() }

        func flip(_ y: CGFloat) -> CGFloat { size.height - y }
        drag(view, CGPoint(x: 262, y: flip(128)), CGPoint(x: 1178, y: flip(700)))

        state.width = .medium
        state.color = .red
        state.tool = .rectangle
        drag(view, CGPoint(x: 1026, y: flip(362)), CGPoint(x: 1162, y: flip(528)))
        state.tool = .pixelate
        drag(view, CGPoint(x: 444, y: flip(553)), CGPoint(x: 724, y: flip(664)))
        state.width = .thick
        state.tool = .arrow
        drag(view, CGPoint(x: 764, y: flip(402)), CGPoint(x: 1018, y: flip(438)))
        state.color = .yellow
        state.width = .medium
        state.tool = .ellipse
        drag(view, CGPoint(x: 560, y: flip(294)), CGPoint(x: 652, y: flip(340)))
        state.color = .red
        state.width = .thick
        state.tool = .text
        click(view, CGPoint(x: 470, y: flip(392)))
        if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
            field.stringValue = T("shots.mark")
        }
        state.tool = .arrow // commits the text and leaves the arrow tool lit
        view.layoutSubtreeIfNeeded()

        let image = NSImage(size: size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        window.orderOut(nil)
        return image
    }

    private static func event(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func drag(_ view: NSView, _ a: CGPoint, _ b: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, a, in: view))
        for step in 1...8 {
            let t = CGFloat(step) / 8
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), in: view))
        }
        view.mouseUp(with: event(.leftMouseUp, b, in: view))
    }

    private static func click(_ view: NSView, _ point: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, point, in: view))
        view.mouseUp(with: event(.leftMouseUp, point, in: view))
    }

    // MARK: - Shot 3: the recording toolbar

    private static func recordingBar() -> some View {
        CaptureActionBar(mode: .recording, state: CaptureToolState(), settings: AppSettings.shared, perform: { _ in })
    }

    private static func recordingBarSize() -> CGSize {
        NSHostingView(rootView: recordingBar()).fittingSize
    }

    // MARK: - Shot 4: thumbnails

    private static func thumbnails() -> [NSImage] {
        let scenes: [AnyView] = [
            AnyView(DesktopScene()),
            AnyView(DesktopScene(window: .notes)),
            AnyView(DesktopScene(window: .design)),
            AnyView(DesktopScene(window: .code)),
            AnyView(DesktopScene(window: .notes, wallpaper: 1)),
            AnyView(DesktopScene(wallpaper: 2)),
        ]
        return scenes.map { scene in
            image(scene.scaleEffect(0.5, anchor: .topLeading).frame(width: 720, height: 450, alignment: .topLeading),
                  size: CGSize(width: 720, height: 450))
        }
    }
}

/// A line of the shots in the language being rendered.
@MainActor
private func T(_ key: String) -> String {
    FeatureShots.strings[key] ?? FeatureShots.english[key] ?? key
}

// MARK: - The frame every shot shares

private struct ShotFrame<Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let glow: [Color]
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            content

            VStack(spacing: 0) {
                Text(eyebrow.uppercased(with: LanguageBundle.locale))
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(3.5)
                    .foregroundStyle(LinearGradient(colors: glow, startPoint: .leading, endPoint: .trailing))
                    .lineLimit(1)
                // One line, whatever the language: a long headline shrinks
                // rather than wrapping into the screen below it.
                Text(title)
                    .font(.system(size: 60, weight: .heavy))
                    .tracking(-1.4)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: 1340)
                    .padding(.top, 10)
                Text(subtitle)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 1000)
                    .padding(.top, 12)
            }
            .environment(\.layoutDirection, FeatureShots.isRightToLeft ? .rightToLeft : .leftToRight)
            .padding(.top, 58)
        }
        .frame(width: FeatureShots.size.width, height: FeatureShots.size.height, alignment: .top)
        // In the background, where their size cannot push the layout about.
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.09), Color(red: 0.02, green: 0.02, blue: 0.04)],
                               startPoint: .top, endPoint: .bottom)
                // Radial gradients rather than blurred circles: a blur does
                // not survive drawing the view into a bitmap.
                Glow(color: glow[0], radius: 620).opacity(0.75).offset(x: -470, y: 420)
                Glow(color: glow[1], radius: 560).opacity(0.7).offset(x: 540, y: 300)
                Glow(color: glow[0], radius: 380).opacity(0.35).offset(x: 60, y: -330)
            }
            .frame(width: FeatureShots.size.width, height: FeatureShots.size.height)
        }
        .clipped()
    }
}

private struct Glow: View {
    let color: Color
    let radius: CGFloat

    var body: some View {
        RadialGradient(colors: [color, color.opacity(0.45), color.opacity(0)], center: .center, startRadius: 0, endRadius: radius)
            .frame(width: radius * 2, height: radius * 2)
    }
}

/// A capsule label with a soft glow, pointing at something with its tail.
private struct Callout: View {
    let text: String
    var symbol: String?
    let colors: [Color]
    var tail: Edge? = .bottom
    /// The room to its right on the page; a longer translation shrinks to fit.
    var maxWidth: CGFloat = 560

    var body: some View {
        HStack(spacing: 9) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 19, weight: .bold))
            }
            Text(text).font(.system(size: 21, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .overlay(alignment: tail == .bottom ? .bottom : .top) {
            if tail != nil {
                Triangle()
                    .fill(colors.last ?? .blue)
                    .frame(width: 22, height: 12)
                    .rotationEffect(.degrees(tail == .bottom ? 0 : 180))
                    .offset(y: tail == .bottom ? 11 : -11)
            }
        }
        .shadow(color: (colors.first ?? .blue).opacity(0.55), radius: 22, y: 10)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// A screen, as a picture on the page: rounded, with a thin bezel and a deep
/// shadow, so the scene reads as a Mac and not as a flat illustration.
private struct Display<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let scale = width / FeatureShots.size.width
        content
            .frame(width: FeatureShots.size.width, height: FeatureShots.size.height)
            .scaleEffect(scale)
            .frame(width: width, height: FeatureShots.size.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.6), radius: 50, y: 26)
    }
}

// MARK: - The desktop the features are shown on

private enum MockWindow {
    case dashboard, notes, design, code
}

private struct DesktopScene: View {
    var window: MockWindow = .dashboard
    var wallpaper = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper(variant: wallpaper)
            MenuBarStrip()
            switch window {
            case .dashboard:
                DashboardWindow().frame(width: 940, height: 600).offset(x: 250, y: 110)
            case .notes:
                NotesWindow(title: T("notes.title")).frame(width: 820, height: 600).offset(x: 310, y: 120)
            case .design:
                DesignWindow().frame(width: 960, height: 620).offset(x: 240, y: 110)
            case .code:
                CodeWindow().frame(width: 900, height: 600).offset(x: 270, y: 120)
            }
        }
        .frame(width: FeatureShots.size.width, height: FeatureShots.size.height, alignment: .topLeading)
    }
}

private struct Wallpaper: View {
    var variant = 0

    var body: some View {
        let palettes: [[Color]] = [
            [Color(red: 0.13, green: 0.10, blue: 0.35), Color(red: 0.36, green: 0.14, blue: 0.48), Color(red: 0.95, green: 0.45, blue: 0.40)],
            [Color(red: 0.05, green: 0.20, blue: 0.30), Color(red: 0.10, green: 0.45, blue: 0.50), Color(red: 0.55, green: 0.85, blue: 0.75)],
            [Color(red: 0.20, green: 0.08, blue: 0.10), Color(red: 0.55, green: 0.18, blue: 0.20), Color(red: 1.0, green: 0.70, blue: 0.40)],
        ]
        let colors = palettes[variant % palettes.count]
        return LinearGradient(colors: [colors[0], colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                ZStack {
                    Glow(color: colors[2], radius: 620).opacity(0.7).offset(x: 480, y: 320)
                    Glow(color: colors[1], radius: 520).opacity(0.8).offset(x: -520, y: -240)
                }
            }
            .frame(width: FeatureShots.size.width, height: FeatureShots.size.height)
            .clipped()
    }
}

private struct MenuBarStrip: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "applelogo").font(.system(size: 14, weight: .medium))
            Text("Northstar").font(.system(size: 13, weight: .bold))
            ForEach(["menu.file", "menu.edit", "menu.view", "menu.window", "menu.help"], id: \.self) { Text(T($0)).font(.system(size: 13)) }
            Spacer()
            Image(systemName: "clipboard.fill").font(.system(size: 13))
            Image(systemName: "wifi").font(.system(size: 13))
            Image(systemName: "battery.75percent").font(.system(size: 14))
            Text(T("menu.clock")).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(width: FeatureShots.size.width, height: 26)
        .background(.black.opacity(0.28))
    }
}

private struct WindowChrome<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.19)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                    Spacer()
                }
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color(white: 0.17))
            content
        }
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
    }
}

/// A revenue dashboard with fixed geometry, so the marks in the first shot
/// land where they are meant to.
private struct DashboardWindow: View {
    var body: some View {
        WindowChrome(title: T("dash.window")) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([("square.grid.2x2", "dash.overview"), ("chart.bar.fill", "dash.revenue"), ("person.2", "dash.customers"),
                             ("doc.text", "dash.reports"), ("gearshape", "dash.settings")], id: \.1) { icon, name in
                        Label(T(name), systemImage: icon)
                            .font(.system(size: 14, weight: name == "dash.revenue" ? .semibold : .regular))
                            .foregroundStyle(name == "dash.revenue" ? .white : .white.opacity(0.6))
                            .padding(.horizontal, 10)
                            .frame(width: 146, height: 32, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7).fill(name == "dash.revenue" ? Color.blue.opacity(0.35) : .clear))
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 170)
                .background(Color(white: 0.13))

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(T("dash.revenue")).font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        Text(T("dash.quarter")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                    .frame(height: 40)
                    HStack(spacing: 14) {
                        kpi(T("dash.revenue"), "$482K", "+14%", .green)
                        kpi(T("dash.customers"), "12,840", "+6%", .green)
                        kpi(T("dash.churn"), "1.9%", "−0.4%", .green)
                    }
                    .frame(height: 96)
                    chart.frame(height: 180)
                    VStack(spacing: 0) {
                        row("jane.cooper@acme.com", T("dash.enterprise"), "$24,000")
                        row("m.alvarez@globex.io", T("dash.team"), "$8,400")
                        row("s.kim@initech.co", T("dash.team"), "$6,900")
                    }
                }
                .padding(24)
            }
        }
    }

    private func kpi(_ name: String, _ value: String, _ change: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                Text(change).font(.system(size: 14, weight: .bold)).foregroundStyle(color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
    }

    private var chart: some View {
        let values: [CGFloat] = [0.38, 0.44, 0.41, 0.52, 0.49, 0.58, 0.55, 0.63, 0.61, 0.70, 0.82, 0.97]
        return HStack(alignment: .bottom, spacing: 12) {
            ForEach(values.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 5)
                    .fill(index >= 10
                          ? AnyShapeStyle(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: [Color.blue.opacity(0.9), Color.blue.opacity(0.45)], startPoint: .top, endPoint: .bottom)))
                    .frame(height: 148 * values[index])
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
    }

    private func row(_ email: String, _ plan: String, _ amount: String) -> some View {
        HStack {
            Text(email).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(plan).font(.system(size: 14)).foregroundStyle(.white.opacity(0.55)).frame(width: 110, alignment: .leading)
            Text(amount).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white).frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }
}

private struct NotesWindow: View {
    let title: String

    var body: some View {
        WindowChrome(title: T("notes.window")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                ForEach(["notes.l1", "notes.l2", "notes.l3", "notes.l4"].map(T), id: \.self) { line in
                    HStack(spacing: 10) {
                        Image(systemName: "circle").foregroundStyle(.orange)
                        Text(line).foregroundStyle(.white.opacity(0.85))
                    }
                    .font(.system(size: 17))
                }
                Spacer()
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.12, green: 0.11, blue: 0.10))
        }
    }
}

private struct DesignWindow: View {
    var body: some View {
        WindowChrome(title: T("design.window")) {
            ZStack {
                Color(white: 0.16)
                VStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 560, height: 220)
                        .overlay(Text(T("design.hero")).font(.system(size: 40, weight: .heavy)).foregroundStyle(.white))
                    HStack(spacing: 16) {
                        ForEach(0..<3) { _ in
                            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)).frame(width: 176, height: 140)
                        }
                    }
                }
            }
        }
    }
}

private struct CodeWindow: View {
    var body: some View {
        WindowChrome(title: "CheckoutView.swift") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array([
                    ("struct", " CheckoutView: View {"), ("    let", " cart: Cart"), ("    var", " body: some View {"),
                    ("        VStack", " {"), ("            Text", "(cart.total, format: .currency)"),
                    ("            Button", "(\"Pay\") { cart.pay() }"), ("        }", ""), ("    }", ""), ("}", ""),
                ].enumerated()), id: \.offset) { _, line in
                    (Text(line.0).foregroundColor(.pink) + Text(line.1).foregroundColor(.white.opacity(0.85)))
                        .font(.system(size: 17, design: .monospaced))
                }
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.11, green: 0.11, blue: 0.14))
        }
    }
}

// MARK: - Shot 1

private struct MarkupShot: View {
    let overlay: NSImage

    var body: some View {
        ShotFrame(
            eyebrow: T("shots.eyebrow"),
            title: T("shots.title"),
            subtitle: T("shots.sub"),
            glow: [Color(red: 1, green: 0.30, blue: 0.40), Color(red: 1, green: 0.62, blue: 0.20)]
        ) {
            ZStack(alignment: .topLeading) {
                Display(width: 1180) {
                    Image(nsImage: overlay).resizable()
                }
                .offset(x: 130, y: 250)

                Callout(text: T("shots.tag.arrows"), colors: [Color(red: 1, green: 0.30, blue: 0.40), Color(red: 1, green: 0.45, blue: 0.30)], tail: nil, maxWidth: 290)
                    .offset(x: 1136, y: 560)
                Callout(text: T("shots.tag.blur"), colors: [Color(red: 0.55, green: 0.35, blue: 1), Color(red: 0.35, green: 0.45, blue: 1)], tail: nil)
                    .offset(x: 46, y: 712)
                Callout(text: T("shots.tag.copy"), colors: [Color(red: 1, green: 0.55, blue: 0.15), Color(red: 1, green: 0.40, blue: 0.25)], tail: nil, maxWidth: 316)
                    .offset(x: 1112, y: 818)
            }
            .frame(width: FeatureShots.size.width, height: FeatureShots.size.height, alignment: .topLeading)
        }
    }
}

// MARK: - Shot 2

private struct RecordingShot: View {
    var body: some View {
        ShotFrame(
            eyebrow: T("rec.eyebrow"),
            title: T("rec.title"),
            subtitle: T("rec.sub"),
            glow: [Color(red: 0.95, green: 0.20, blue: 0.35), Color(red: 0.55, green: 0.25, blue: 1)]
        ) {
            ZStack(alignment: .topLeading) {
                Display(width: 1180) {
                    ZStack(alignment: .topLeading) {
                        DesktopScene()
                        // The frame round the recorded area.
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                            .foregroundStyle(.red)
                            .frame(width: 956, height: 616)
                            .offset(x: 242, y: 102)
                        // A loop drawn round the best months, as it would be mid-talk.
                        Scribble()
                            .stroke(.red, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                            .frame(width: 180, height: 220)
                            .offset(x: 1000, y: 330)
                        ClickBurst()
                            .scaleEffect(1.35)
                            .offset(x: 1040 - 60, y: 176 - 60)
                        PresenterBubble()
                            .offset(x: 205, y: 520)
                        RecordingControlsView(recorder: ScreenRecorder.shared)
                            .scaleEffect(1.3)
                            .offset(x: 530, y: 732)
                    }
                }
                .offset(x: 130, y: 250)

                Callout(text: T("rec.tag.bubble"), colors: [Color(red: 0.55, green: 0.25, blue: 1), Color(red: 0.75, green: 0.30, blue: 1)], tail: nil)
                    .offset(x: 36, y: 700)
                Callout(text: T("rec.tag.clicks"), colors: [Color(red: 0.2, green: 0.55, blue: 1), Color(red: 0.35, green: 0.45, blue: 1)], tail: nil, maxWidth: 360)
                    .offset(x: 1070, y: 358)
                Callout(text: T("rec.tag.controls"), colors: [Color(red: 0.95, green: 0.20, blue: 0.35), Color(red: 1, green: 0.40, blue: 0.35)], tail: nil, maxWidth: 430)
                    .offset(x: 1000, y: 832)
            }
            .frame(width: FeatureShots.size.width, height: FeatureShots.size.height, alignment: .topLeading)
        }
    }
}

private struct Scribble: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let rx = rect.width / 2, ry = rect.height / 2
            path.move(to: CGPoint(x: c.x + rx * 0.9, y: c.y - ry * 0.55))
            for step in 1...64 {
                let t = CGFloat(step) / 64 * 2.15 * .pi - 0.55
                let wobble = 1 + 0.05 * sin(t * 5)
                path.addLine(to: CGPoint(x: c.x + cos(t) * rx * wobble, y: c.y + sin(t) * ry * wobble))
            }
        }
    }
}

/// A click burst frozen mid-flight: the ring opening out and the dots
/// flying from it, drawn as the recording canvas draws them.
private struct ClickBurst: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.blue.opacity(0.22)).frame(width: 34, height: 34)
            Circle().strokeBorder(Color.blue, lineWidth: 3).frame(width: 60, height: 60)
                .shadow(color: .blue, radius: 6)
            Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.2).frame(width: 54, height: 54)
            ForEach(0..<10, id: \.self) { index in
                let angle = Double(index) / 10 * 2 * .pi
                let distance: CGFloat = index.isMultiple(of: 2) ? 52 : 42
                Circle().fill(Color.blue).frame(width: index.isMultiple(of: 2) ? 8 : 6)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 0.8))
                    .shadow(color: .blue, radius: 3)
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance)
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.black)
                .background(Image(systemName: "cursorarrow").font(.system(size: 34, weight: .heavy)).foregroundStyle(.white))
                .offset(x: 12, y: 16)
        }
        .frame(width: 120, height: 120)
    }
}

/// The presenter in the camera bubble. There is no camera here, so the
/// person is drawn — a friendly portrait rather than a stand-in rectangle.
private struct PresenterBubble: View {
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 0.95), Color(red: 0.55, green: 0.40, blue: 0.95)],
                                         startPoint: .top, endPoint: .bottom))
            // Shoulders
            Ellipse()
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.35), Color(red: 0.90, green: 0.40, blue: 0.30)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 170, height: 120)
                .offset(y: 92)
            // Neck and head
            Capsule().fill(Color(red: 0.93, green: 0.72, blue: 0.58)).frame(width: 34, height: 40).offset(y: 30)
            Ellipse().fill(Color(red: 0.96, green: 0.77, blue: 0.62)).frame(width: 74, height: 88).offset(y: -12)
            // Hair
            Ellipse().fill(Color(red: 0.25, green: 0.16, blue: 0.12)).frame(width: 84, height: 52).offset(y: -44)
            Capsule().fill(Color(red: 0.25, green: 0.16, blue: 0.12)).frame(width: 16, height: 56).offset(x: -38, y: -18)
            Capsule().fill(Color(red: 0.25, green: 0.16, blue: 0.12)).frame(width: 16, height: 56).offset(x: 38, y: -18)
            // Face
            HStack(spacing: 20) {
                Circle().fill(Color(red: 0.2, green: 0.14, blue: 0.12)).frame(width: 7, height: 7)
                Circle().fill(Color(red: 0.2, green: 0.14, blue: 0.12)).frame(width: 7, height: 7)
            }
            .offset(y: -12)
            Capsule().trim(from: 0.5, to: 1).stroke(Color(red: 0.7, green: 0.3, blue: 0.28), lineWidth: 3)
                .frame(width: 22, height: 12).rotationEffect(.degrees(180)).offset(y: 10)
        }
        .frame(width: 200, height: 200)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.95), lineWidth: 4))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}

// MARK: - Shot 3

private struct ChooseShot: View {
    let bar: NSImage

    private let tint = [Color(red: 0.15, green: 0.75, blue: 0.85), Color(red: 0.25, green: 0.50, blue: 1)]
    private let barScale: CGFloat = 1.3
    private let barTop: CGFloat = 690

    var body: some View {
        let displayScale = 1180 / FeatureShots.size.width
        let barLeft = 720 - bar.size.width * barScale / 2
        // The three mode buttons sit first on the bar: 4 points in, 30 wide,
        // 2 apart. Their middle, in the shot's own coordinates.
        let modesCentre = 130 + (barLeft + (4 + 47) * barScale) * displayScale
        let barTopInShot = 250 + barTop * displayScale

        return ShotFrame(
            eyebrow: T("choose.eyebrow"),
            title: T("choose.title"),
            subtitle: T("choose.sub"),
            glow: tint
        ) {
            ZStack(alignment: .topLeading) {
                Display(width: 1180) {
                    ZStack(alignment: .topLeading) {
                        Wallpaper(variant: 1)
                        MenuBarStrip()
                        DashboardWindow().frame(width: 840, height: 540).offset(x: 60, y: 90)
                        NotesWindow(title: T("notes.title")).frame(width: 440, height: 440).offset(x: 940, y: 150)
                        // The overlay's dimming, with the window under the
                        // pointer lit as the picker lights it.
                        Color.black.opacity(0.42)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.16))
                            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue, lineWidth: 4)
                            Label(T("choose.window"), systemImage: "macwindow")
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20).padding(.vertical, 12)
                                .background(Capsule().fill(Color.blue))
                                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                                .padding(.bottom, 34)
                        }
                        .frame(width: 440, height: 440)
                        .offset(x: 940, y: 150)
                        Image(nsImage: bar)
                            .resizable()
                            .frame(width: bar.size.width * barScale, height: bar.size.height * barScale)
                            .offset(x: barLeft, y: barTop)
                    }
                }
                .offset(x: 130, y: 250)

                // The first three buttons, magnified and named.
                ModeMagnifier(colors: tint)
                    .position(x: modesCentre, y: barTopInShot - 92)
            }
            .frame(width: FeatureShots.size.width, height: FeatureShots.size.height, alignment: .topLeading)
        }
    }
}

private struct ModeMagnifier: View {
    let colors: [Color]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                tile("display", T("choose.mode.screen"))
                tile("macwindow", T("choose.mode.window"))
                tile("app.dashed", T("choose.mode.app"))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing), lineWidth: 2))
            .shadow(color: (colors.first ?? .blue).opacity(0.5), radius: 26, y: 10)
            Triangle()
                .fill(colors.last ?? .blue)
                .frame(width: 26, height: 14)
        }
        .fixedSize()
    }

    private func tile(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 50)
                .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 150)
        .padding(.vertical, 6)
    }
}

// MARK: - Shot 4

private struct LibraryShot: View {
    let thumbnails: [NSImage]

    private var recordings: [RecordingLibrary.Recording] {
        let names = (1...6).map { T("lib.rec\($0)") }
        let lengths: [TimeInterval] = [134, 222, 95, 48, 301, 176]
        let ages: [TimeInterval] = [60 * 12, 60 * 60 * 3, 60 * 60 * 26, 60 * 60 * 50, 60 * 60 * 24 * 4, 60 * 60 * 24 * 6]
        return names.indices.map { index in
            RecordingLibrary.Recording(
                url: URL(fileURLWithPath: "/tmp/\(index).mov"),
                name: names[index],
                created: Date().addingTimeInterval(-ages[index]),
                bytes: Int64([38, 61, 24, 12, 88, 47][index]) * 1_000_000,
                duration: lengths[index]
            )
        }
    }

    var body: some View {
        ShotFrame(
            eyebrow: T("lib.eyebrow"),
            title: T("lib.title"),
            subtitle: T("lib.sub"),
            glow: [Color(red: 0.45, green: 0.30, blue: 1), Color(red: 0.95, green: 0.35, blue: 0.75)]
        ) {
            ZStack(alignment: .topLeading) {
                Display(width: 1180) {
                    ZStack(alignment: .topLeading) {
                        Wallpaper(variant: 0)
                        MenuBarStrip()
                        WindowChrome(title: "CopyWell") {
                            HStack(spacing: 0) {
                                sidebar
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(T("ui.recordings")).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(262), spacing: 18), count: 3), spacing: 18) {
                                        ForEach(Array(recordings.enumerated()), id: \.offset) { index, recording in
                                            RecordingCard(recording: recording,
                                                          thumbnail: thumbnails.indices.contains(index) ? thumbnails[index] : nil,
                                                          isSelected: index == 0)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(22)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(Color(white: 0.09))
                            }
                        }
                        .frame(width: 1110, height: 700)
                        .offset(x: 165, y: 70)

                        // The review window's actions, lifted out beside the first card.
                        HStack(spacing: 10) {
                            chip("scissors", T("lib.chip.trim"))
                            chip("doc.on.doc", T("lib.chip.copy"))
                            chip("square.and.arrow.up", T("lib.chip.share"))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.16)))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.14)))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                        .offset(x: 470, y: 440)
                    }
                }
                .offset(x: 130, y: 250)

                Callout(text: T("lib.tag.trim"), colors: [Color(red: 0.45, green: 0.30, blue: 1), Color(red: 0.65, green: 0.35, blue: 1)], tail: .top)
                    .offset(x: 600, y: 700)
                Callout(text: T("lib.tag.chat"), colors: [Color(red: 0.95, green: 0.35, blue: 0.75), Color(red: 1, green: 0.45, blue: 0.55)], tail: nil, maxWidth: 440)
                    .offset(x: 990, y: 268)
            }
            .frame(width: FeatureShots.size.width, height: FeatureShots.size.height, alignment: .topLeading)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(T("ui.library").uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 10).padding(.bottom, 4)
            ForEach([("clock", "ui.history", "248"), ("star", "ui.favourites", "12"), ("square.stack", "ui.pasteStack", "3"),
                     ("film.stack", "ui.recordings", "6")], id: \.1) { icon, name, count in
                HStack {
                    Label(T(name), systemImage: icon).font(.system(size: 14, weight: name == "ui.recordings" ? .semibold : .regular))
                    Spacer()
                    Text(count).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                .foregroundStyle(.white.opacity(name == "ui.recordings" ? 1 : 0.75))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(name == "ui.recordings" ? Color.accentColor.opacity(0.45) : .clear))
            }
            Text(T("ui.pinboards").uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            ForEach([("briefcase.fill", T("ui.board.work"), Color.orange), ("sparkles", T("ui.board.snippets"), Color.purple)], id: \.1) { icon, name, color in
                Label { Text(name) } icon: { Image(systemName: icon).foregroundStyle(color) }
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10).frame(height: 30)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.13))
    }

    private func chip(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1)))
    }
}
#endif
