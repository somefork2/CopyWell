import AppKit
import Observation
import SwiftUI

// MARK: - The image viewer window

/// A clip's image at full size, in a window of its own.
///
/// The previews in the palette, the menu bar popover and the main window are
/// thumbnails sized to their surface; this is where an image can be read. It
/// opens fitted to the screen (never enlarged past 100%), zooms with a pinch,
/// ⌘+ / ⌘− and the bar's buttons, toggles between fitted and actual size on a
/// double-click, and closes with Esc. One window per clip: asking again brings
/// the open one forward.
@MainActor
final class ImageViewer: NSObject, NSWindowDelegate {
    private static var open: [UUID: ImageViewer] = [:]

    private let id: UUID
    private let window: ViewerWindow
    private let scrollView = NSScrollView()
    fileprivate let model = ImageViewerModel()

    static func show(_ item: ClipboardItem) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = open[item.id] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let image = item.imageData.flatMap(NSImage.init(data:)), image.size.width > 0, image.size.height > 0 else {
            NSSound.beep()
            return
        }
        let viewer = ImageViewer(item: item, image: image)
        open[item.id] = viewer
        viewer.window.makeKeyAndOrderFront(nil)
    }

    private init(item: ClipboardItem, image: NSImage) {
        id = item.id
        window = ViewerWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = item.displayTitle
        window.subtitle = item.imageSummary
        window.minSize = CGSize(width: 380, height: 280)
        window.onKey = { [weak self] key in self?.handle(key) ?? false }

        let imageView = NSImageView(frame: CGRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleFit(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        model.zoomIn = { [weak self] in self?.zoom(by: 1.25) }
        model.zoomOut = { [weak self] in self?.zoom(by: 0.8) }
        model.fit = { [weak self] in self?.fitToWindow() }
        model.actualSize = { [weak self] in self?.setZoom(1) }
        model.copy = { if let content = item.pasteContent { PasteService.write(content) } }
        let bar = NSHostingView(rootView: ImageViewerBar(model: model))
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scrollView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content

        // Big enough to show the image at 100% when the screen allows it, and
        // fitted to the screen when it does not.
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let room = CGSize(width: screen.width * 0.9, height: screen.height * 0.9)
        let chrome = window.frameRect(forContentRect: .zero).size
        let scale = min(1, (room.width - chrome.width) / image.size.width, (room.height - chrome.height) / image.size.height)
        let contentSize = CGSize(width: max(window.minSize.width, (image.size.width * scale).rounded()),
                                 height: max(window.minSize.height, (image.size.height * scale).rounded()))
        window.setContentSize(contentSize)
        window.setFrameOrigin(CGPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2))
        content.layoutSubtreeIfNeeded()
        setZoom(scale)
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        Self.open[id] = nil
    }

    // MARK: - Zoom

    private var fittedMagnification: CGFloat {
        guard let size = scrollView.documentView?.frame.size, size.width > 0, size.height > 0 else { return 1 }
        let visible = scrollView.contentSize
        return min(1, visible.width / size.width, visible.height / size.height)
    }

    private func setZoom(_ value: CGFloat, around point: CGPoint? = nil) {
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        let center = point ?? CGPoint(x: scrollView.documentVisibleRect.midX, y: scrollView.documentVisibleRect.midY)
        scrollView.setMagnification(clamped, centeredAt: center)
        magnificationChanged()
    }

    private func zoom(by factor: CGFloat) { setZoom(scrollView.magnification * factor) }

    private func fitToWindow() { setZoom(fittedMagnification) }

    @objc private func toggleFit(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: scrollView.documentView)
        if abs(scrollView.magnification - fittedMagnification) < 0.01, fittedMagnification < 1 {
            setZoom(1, around: point)
        } else {
            fitToWindow()
        }
    }

    @objc private func magnificationChanged() {
        model.zoom = scrollView.magnification
    }

    /// Matched on key codes, not characters, so the shortcuts work on any
    /// keyboard layout (on a Russian one "=" and "-" are still there, but
    /// "W" types "Ц").
    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, command) {
        case (53, _): window.close()                       // Esc
        case (13, true): window.close()                    // ⌘W
        case (24, true), (69, true): zoom(by: 1.25)        // ⌘= / ⌘+ (keypad)
        case (27, true), (78, true): zoom(by: 0.8)         // ⌘- (and keypad)
        case (29, true): setZoom(1)                        // ⌘0, actual size
        case (25, true): fitToWindow()                     // ⌘9, fit
        case (8, true): model.copy?(); model.flashCopied() // ⌘C
        default: return false
        }
        return true
    }
}

/// Hands key presses to the viewer before the menu sees them.
private final class ViewerWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

/// Keeps an image smaller than the window in the middle of it, the way
/// Preview does, instead of pinned to the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

// MARK: - The bar

@MainActor
@Observable
final class ImageViewerModel {
    var zoom: CGFloat = 1
    var copied = false
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
    var fit: (() -> Void)?
    var actualSize: (() -> Void)?
    var copy: (() -> Void)?

    func flashCopied() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copied = false }
    }
}

private struct ImageViewerBar: View {
    let model: ImageViewerModel

    var body: some View {
        HStack(spacing: 2) {
            button("minus", L("Zoom out")) { model.zoomOut?() }
            Button { model.actualSize?() } label: {
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 46)
            }
            .buttonStyle(.hoverPlate(padding: 5, cornerRadius: 7))
            .help(L("Actual size"))
            button("plus", L("Zoom in")) { model.zoomIn?() }
            Divider().frame(height: 18).padding(.horizontal, 4)
            button("arrow.down.right.and.arrow.up.left", L("Fit to window")) { model.fit?() }
            button("1.magnifyingglass", L("Actual size")) { model.actualSize?() }
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button {
                model.copy?()
                model.flashCopied()
            } label: {
                Label(model.copied ? L("Copied") : L("Copy"),
                      systemImage: model.copied ? "checkmark" : "doc.on.doc")
                    .font(.callout)
            }
            .buttonStyle(.hoverPlate(padding: 5, cornerRadius: 7))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
    }

    private func button(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.hoverPlate(padding: 5, cornerRadius: 7))
        .help(tip)
        .accessibilityLabel(tip)
    }
}

// MARK: - Opening it from a preview

/// A preview image that opens the viewer when clicked, with a hint on hover
/// that it can.
struct ExpandableImage: View {
    let image: NSImage
    let item: ClipboardItem
    var maxHeight: CGFloat? = nil
    var cornerRadius: CGFloat = 6

    @State private var isHovered = false

    var body: some View {
        Button { ImageViewer.show(item) } label: {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Theme.separator, lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                        .opacity(isHovered ? 1 : 0)
                }
                .brightness(isHovered ? -0.03 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L("Open full size"))
        .accessibilityLabel(L("Open full size"))
    }
}

// MARK: - Diagnostics

#if DEBUG
extension ImageViewer {
    static var isDiagnosing: Bool { CommandLine.arguments.contains("--diagnose-image-viewer") }

    /// Opens the viewer on a large and a small synthetic image, drives zoom
    /// with the shortcuts (typed as on a Russian layout, to prove they go by
    /// key code) and the bar, and checks the window fits the screen, the
    /// small image sits centred at 100%, a second request reuses the window,
    /// and Esc closes it. Pictures of both land in Documents/Screenshots.
    static func diagnose() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        func synthetic(_ size: CGSize) -> Data {
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                NSColor.systemBlue.withAlphaComponent(0.25).setStroke()
                for x in stride(from: 0, to: rect.width, by: 50) { NSBezierPath.strokeLine(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: rect.height)) }
                for y in stride(from: 0, to: rect.height, by: 50) { NSBezierPath.strokeLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: rect.width, y: y)) }
                NSString(string: "\(Int(size.width)) × \(Int(size.height))").draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold)])
                return true
            }
            return ImageStore.png(from: image, maxSize: nil) ?? Data()
        }
        func key(_ code: UInt16, _ characters: String, command: Bool = true) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [],
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func snap(_ viewer: ImageViewer, _ name: String) {
            guard let view = viewer.window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }

        // Large image.
        let bigName = "diagnose-viewer-big.png", smallName = "diagnose-viewer-small.png"
        ImageStore.write(data: synthetic(CGSize(width: 3200, height: 2000)), fileName: bigName)
        ImageStore.write(data: synthetic(CGSize(width: 240, height: 120)), fileName: smallName)
        defer { ImageStore.remove(fileName: bigName); ImageStore.remove(fileName: smallName) }

        let big = ClipboardItem(contentType: .image, contentHash: "diagnose-big", imageFileName: bigName)
        show(big)
        guard let viewer = open[big.id] else { print("RESULT: viewer did not open"); exit(2) }
        let visible = (viewer.window.screen ?? NSScreen.main)!.visibleFrame
        check(viewer.window.isVisible, "large: window is on screen")
        check(visible.contains(viewer.window.frame), "large: window fits the screen \(NSStringFromRect(viewer.window.frame))")
        check(viewer.scrollView.magnification < 1 && abs(viewer.scrollView.magnification - viewer.fittedMagnification) < 0.02,
              "large: opens fitted (\(viewer.scrollView.magnification))")
        snap(viewer, "viewer-large-fitted.png")

        _ = viewer.handle(key(29, "0"))                     // ⌘0
        check(abs(viewer.scrollView.magnification - 1) < 0.001, "⌘0: actual size")
        check(abs(viewer.model.zoom - 1) < 0.001, "bar shows 100%")
        snap(viewer, "viewer-large-100.png")
        _ = viewer.handle(key(27, "-"))                     // ⌘-
        check(abs(viewer.scrollView.magnification - 0.8) < 0.001, "⌘−: zooms out")
        _ = viewer.handle(key(24, "="))                     // ⌘=
        check(abs(viewer.scrollView.magnification - 1) < 0.001, "⌘=: zooms in")
        _ = viewer.handle(key(25, "9"))                     // ⌘9
        check(abs(viewer.scrollView.magnification - viewer.fittedMagnification) < 0.02, "⌘9: fits again")
        viewer.model.actualSize?()
        check(abs(viewer.scrollView.magnification - 1) < 0.001, "bar: actual size button")
        viewer.model.fit?()
        check(viewer.scrollView.magnification < 1, "bar: fit button")
        viewer.model.zoomIn?()
        check(viewer.scrollView.magnification > viewer.fittedMagnification, "bar: zoom in button")

        show(big)
        check(open.count == 1, "asking again reuses the window")

        _ = viewer.handle(key(13, "ц"))                     // ⌘W on a Russian layout
        check(open[big.id] == nil && !viewer.window.isVisible, "⌘W (Russian layout) closes")

        // Small image: 100%, centred, Esc closes.
        let small = ClipboardItem(contentType: .image, contentHash: "diagnose-small", imageFileName: smallName)
        show(small)
        guard let tiny = open[small.id] else { print("RESULT: small viewer did not open"); exit(2) }
        check(abs(tiny.scrollView.magnification - 1) < 0.001, "small: opens at 100%, not enlarged")
        let bounds = tiny.scrollView.contentView.bounds
        check(bounds.minX < 0 && bounds.minY < 0, "small: image is centred (clip origin \(NSStringFromPoint(bounds.origin)))")
        snap(tiny, "viewer-small.png")
        _ = tiny.handle(key(53, "\u{1b}", command: false))   // Esc
        check(open[small.id] == nil, "Esc closes")

        // A clip whose file is gone: no window, no crash.
        let missing = ClipboardItem(contentType: .image, contentHash: "diagnose-missing", imageFileName: "diagnose-viewer-missing.png")
        show(missing)
        check(open[missing.id] == nil, "missing file: nothing opens")

        print("RESULT: \(failures == 0 ? "all passed" : "\(failures) failed"), pictures in \(directory.path)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
