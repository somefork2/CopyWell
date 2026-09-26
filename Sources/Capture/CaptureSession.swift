import AppKit
import ScreenCaptureKit

/// One run of the capture overlay across every screen, from the moment it
/// appears to the choice the user makes in it.
@MainActor
final class CaptureSession: NSObject, CaptureOverlayDelegate {
    enum Outcome {
        case image(CGImage, pointSize: CGSize, action: CaptureAction)
        case record(screen: NSScreen, rect: CGRect)
        /// A window or an app, to be chosen in the system's picker.
        case pick(SCShareableContentStyle)
        case cancelled
    }

    private(set) static var current: CaptureSession?

    let mode: CaptureMode
    private let state = CaptureToolState()
    private var overlays: [(window: CaptureOverlayWindow, view: CaptureOverlayView, screen: NSScreen)] = []
    private let completion: (Outcome) -> Void

    private init(mode: CaptureMode, completion: @escaping (Outcome) -> Void) {
        self.mode = mode
        self.completion = completion
    }

    /// Puts the overlay up. Screenshots show the frozen pictures; recordings
    /// get a see-through overlay over the live screens.
    static func present(mode: CaptureMode, snapshots: [ScreenSnapshot], completion: @escaping (Outcome) -> Void) {
        current?.finish(.cancelled)
        let session = CaptureSession(mode: mode, completion: completion)
        current = session
        session.show(snapshots)
    }

    static func cancelCurrent() {
        current?.finish(.cancelled)
    }

    private func show(_ snapshots: [ScreenSnapshot]) {
        let screens: [(NSScreen, CGImage?)] = mode == .screenshot
            ? snapshots.map { ($0.screen, $0.image) }
            : NSScreen.screens.map { ($0, nil) }

        state.onChange = { [weak self] in
            self?.overlays.forEach { $0.view.toolDidChange() }
        }
        state.onTipChange = { [weak self] in
            self?.overlays.forEach { $0.view.tipDidChange() }
        }

        for (screen, image) in screens {
            let window = CaptureOverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            // Above the menu bar and the Dock, both of which can be part of
            // what is being captured.
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.setFrame(screen.frame, display: false)

            let view = CaptureOverlayView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                mode: mode,
                snapshot: image,
                state: state
            )
            view.delegate = self
            window.contentView = view
            window.orderFrontRegardless()
            overlays.append((window, view, screen))
        }

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        if let target = overlays.first(where: { $0.screen.frame.contains(mouse) }) ?? overlays.first {
            target.window.makeKeyAndOrderFront(nil)
            target.window.makeFirstResponder(target.view)
        }
    }

    private func finish(_ outcome: Outcome) {
        guard Self.current === self else { return }
        Self.current = nil
        for overlay in overlays {
            overlay.window.orderOut(nil)
            overlay.window.contentView = nil
        }
        overlays.removeAll()
        completion(outcome)
    }

    /// The overlay the user is working in: the one holding a selection.
    private var active: CaptureOverlayView? {
        overlays.first { $0.view.hasSelection }?.view
    }

    // MARK: - CaptureOverlayDelegate

    func overlayDidBeginSelection(_ overlay: CaptureOverlayView) {
        for other in overlays where other.view !== overlay {
            other.view.clearSelection()
        }
    }

    func overlay(_ overlay: CaptureOverlayView, perform action: CaptureAction) {
        switch action {
        case .cancel:
            finish(.cancelled)
        case .undo:
            overlay.undo()
        case .record:
            guard mode == .recording,
                  let screen = overlays.first(where: { $0.view === overlay })?.screen else { return }
            finish(.record(screen: screen, rect: overlay.recordingArea))
        case .recordScreen:
            guard mode == .recording else { return }
            overlayDidBeginSelection(overlay)
            overlay.selectWholeScreen()
        case .recordWindow:
            guard mode == .recording else { return }
            finish(.pick(.window))
        case .recordApp:
            guard mode == .recording else { return }
            finish(.pick(.application))
        case .copy, .save, .copyText:
            guard mode == .screenshot,
                  let selection = overlay.selection,
                  let image = overlay.renderSelection() else { return }
            finish(.image(image, pointSize: selection.size, action: action))
        }
    }

    func overlay(_ overlay: CaptureOverlayView, keyDown event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Matched on the physical key, not the character it types: with a
        // Russian layout ⌘Z arrives as "я", and the shortcut did nothing.
        let code = event.keyCode

        switch Int(event.keyCode) {
        case 53: // ⎋
            finish(.cancelled)
            return true
        case 36, 76: // ⏎ and the keypad's Enter
            if mode == .recording {
                // Nothing selected records the screen the keyboard is on.
                self.overlay(active ?? overlay, perform: .record)
            } else if let active {
                self.overlay(active, perform: .copy)
            }
            return true
        default:
            break
        }

        if flags == .command {
            switch code {
            case 8: // C
                if let active, mode == .screenshot { self.overlay(active, perform: .copy) }
            case 1: // S
                if let active, mode == .screenshot { self.overlay(active, perform: .save) }
            case 6: // Z
                active?.undo()
            case 0: // A
                overlayDidBeginSelection(overlay)
                overlay.selectWholeScreen()
            default:
                return false
            }
            return true
        }

        if flags.isEmpty, mode == .screenshot, active != nil,
           let tool = AnnotationTool.allCases.first(where: { $0.keyCode == code }) {
            state.tool = state.tool == tool ? nil : tool
            return true
        }
        return false
    }
}

/// Takes a screenshot of an area and does what was chosen with it.
@MainActor
enum ScreenshotController {
    static func start() {
        guard CaptureSession.current == nil else {
            CaptureSession.cancelCurrent()
            return
        }
        guard ScreenCaptureAccess.ensure() else { return }
        PasteService.rememberFrontmostApp()
        if QuickPastePanel.shared.isVisible { QuickPastePanel.shared.hide() }

        Task { @MainActor in
            do {
                let snapshots = try await ScreenSnapshotter.snapshotAllScreens()
                guard !snapshots.isEmpty else {
                    CaptureFailure.show(nil)
                    return
                }
                CaptureSession.present(mode: .screenshot, snapshots: snapshots) { outcome in
                    handle(outcome)
                }
            } catch {
                CaptureFailure.show(error)
            }
        }
    }

    private static func handle(_ outcome: CaptureSession.Outcome) {
        switch outcome {
        case .image(let image, let size, .copy):
            copy(image, pointSize: size)
            returnFocus()
        case .image(let image, let size, .save):
            save(image, pointSize: size)
        case .image(let image, let size, .copyText):
            copyText(in: image, pointSize: size)
            returnFocus()
        case .cancelled:
            returnFocus()
        default:
            break
        }
    }

    private static func returnFocus() {
        PasteService.previousApp?.activate()
    }

    /// Onto the clipboard, and into the history like anything else copied.
    private static func copy(_ image: CGImage, pointSize: CGSize) {
        guard let nsImage = putOnPasteboard(image, pointSize: pointSize) else { return }
        SoundPlayer.play(.captured)
        CaptureToast.show(L("Screenshot copied"), symbol: "checkmark.circle.fill")

        Task { @MainActor in
            if let clip = await ClipboardMonitor.makeClip(
                image: nsImage,
                sourceApp: "CopyWell",
                sourceBundleID: Bundle.main.bundleIdentifier
            ) {
                ClipboardStore.shared.insert(clip)
            }
        }
    }

    /// PNG and TIFF, so every app finds a format it takes. Marked as ours so
    /// the monitor does not record it a second time; the caller adds it to
    /// the history itself, with CopyWell as its source.
    @discardableResult
    static func putOnPasteboard(_ image: CGImage, pointSize: CGSize) -> NSImage? {
        guard let png = CaptureImaging.png(from: image, pointSize: pointSize) else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let nsImage = NSImage(cgImage: image, size: pointSize)
        if let tiff = nsImage.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        PasteboardPrivacy.markAsAutoGenerated(pasteboard)
        return nsImage
    }

    private static func save(_ image: CGImage, pointSize: CGSize) {
        guard let png = CaptureImaging.png(from: image, pointSize: pointSize) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = CaptureNaming.screenshotName() + ".png"
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        panel.begin { response in
            MainActor.assumeIsolated {
                if response == .OK, let url = panel.url {
                    do {
                        try png.write(to: url, options: .atomic)
                        CaptureToast.show(L("Screenshot saved"), symbol: "checkmark.circle.fill")
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                }
                returnFocus()
            }
        }
    }

    private static func copyText(in image: CGImage, pointSize: CGSize) {
        guard let png = CaptureImaging.png(from: image, pointSize: pointSize) else { return }
        Task { @MainActor in
            guard let text = await OCRService.shared.recognizeText(in: png) else {
                CaptureToast.show(L("No text found in the selection"), symbol: "text.magnifyingglass")
                return
            }
            PasteService.write(.text(text))
            SoundPlayer.play(.captured)
            CaptureToast.show(L("Text copied"), symbol: "checkmark.circle.fill")
            // The picture is kept too, below the text: the history showed only
            // the words, and the screenshot they came from was gone.
            if let shot = await ClipboardMonitor.makeClip(
                image: NSImage(cgImage: image, size: pointSize),
                sourceApp: "CopyWell",
                sourceBundleID: Bundle.main.bundleIdentifier
            ) {
                ClipboardStore.shared.insert(shot)
            }
            if let clip = await ClipboardMonitor.makeClip(
                text: text,
                sourceApp: "CopyWell",
                sourceBundleID: Bundle.main.bundleIdentifier
            ) {
                ClipboardStore.shared.insert(clip)
            }
        }
    }
}

enum CaptureNaming {
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    static func screenshotName() -> String { L("Screenshot \(stamp())") }
    static func recordingName() -> String { L("Screen Recording \(stamp())") }
}

/// What to say when the screen could not be captured.
@MainActor
enum CaptureFailure {
    static func show(_ error: Error?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("CopyWell could not capture the screen")
        var detail = L("If you have just allowed Screen Recording, macOS applies it only after CopyWell is reopened.")
        if let error {
            detail += "\n\n" + error.localizedDescription
        }
        alert.informativeText = detail
        alert.addButton(withTitle: L("Reopen CopyWell"))
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            relaunch()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(ScreenCaptureAccess.settingsURL)
        default:
            break
        }
    }

    /// Starts a fresh copy of the app and quits this one, which is the only way
    /// a newly granted Screen Recording permission takes effect.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
