#if DEBUG
import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Development only: drives the capture overlay with synthetic mouse events on
/// a made-up screen picture, and writes what it draws to Documents/Screenshots.
///
/// It exists because the real thing needs the Screen Recording permission,
/// which a development build does not have and cannot grant itself — and the
/// overlay's drawing, toolbars and final crop are all ours to get right
/// regardless of where the picture came from.
@MainActor
enum CaptureDiagnostics {
    static var isActive: Bool { CommandLine.arguments.contains("--diagnose-capture") }
    static var isShowingClicks: Bool { CommandLine.arguments.contains("--diagnose-clicks") }
    static var isTestingRecording: Bool { CommandLine.arguments.contains("--diagnose-recording") }
    static var isTestingScreenshotActions: Bool { CommandLine.arguments.contains("--diagnose-screenshot-actions") }

    /// What the buttons under a screenshot do: Copy (clipboard, and the clip
    /// the history would get), the file Save writes, and Copy Text in Image.
    /// The clipboard is put back exactly as it was, and nothing is written to
    /// the history database, which the running copy of CopyWell has open.
    static func testScreenshotActions() {
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ ok: Bool, _ what: String) {
                print((ok ? "PASS  " : "FAIL  ") + what)
                if !ok { failures += 1 }
            }

            // The user's clipboard, every item in every type, to put back.
            let pasteboard = NSPasteboard.general
            let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
                var types: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types { types[type] = item.data(forType: type) }
                return types
            }
            defer {
                pasteboard.clearContents()
                let items = saved.map { types -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }

            // A screenshot with marks, made through the overlay itself.
            let size = CGSize(width: 1440, height: 900)
            guard let picture = syntheticScreen(pixels: CGSize(width: size.width * 2, height: size.height * 2)) else { exit(2) }
            let state = CaptureToolState()
            let (window, view) = host(mode: .screenshot, snapshot: picture, state: state, size: size)
            drag(view, from: CGPoint(x: 280, y: 480), to: CGPoint(x: 900, y: 700))
            state.tool = .arrow
            drag(view, from: CGPoint(x: 800, y: 500), to: CGPoint(x: 700, y: 600))
            guard let selection = view.selection, let image = view.renderSelection() else {
                print("RESULT: the overlay produced no picture"); exit(1)
            }
            window.orderOut(nil)
            print("      screenshot \(image.width)×\(image.height) px, \(Int(selection.width))×\(Int(selection.height)) pt")

            // Copy.
            ScreenshotController.putOnPasteboard(image, pointSize: selection.size)
            let types = pasteboard.types ?? []
            check(types.contains(.png), "Copy puts a PNG on the clipboard")
            check(types.contains(.tiff), "and a TIFF, for apps that only take that")
            if let png = pasteboard.data(forType: .png), let rep = NSBitmapImageRep(data: png) {
                check(rep.pixelsWide == image.width && rep.pixelsHigh == image.height, "at full Retina resolution")
                check(rep.size == selection.size, "and pastes at the size it was on screen")
            } else {
                check(false, "the PNG can be read back")
            }
            check(PasteboardPrivacy.lastSelfWriteChangeCount == pasteboard.changeCount,
                  "the monitor knows it was CopyWell's own copy, so it is not recorded twice")

            // The clip the history gets (built, not stored).
            if let nsImage = NSImage(data: pasteboard.data(forType: .png) ?? Data()),
               let clip = await ClipboardMonitor.makeClip(image: nsImage, sourceApp: "CopyWell", sourceBundleID: Bundle.main.bundleIdentifier) {
                check(clip.contentType == .image, "the history gets an image clip")
                check(clip.pixelWidth == image.width && clip.pixelHeight == image.height, "kept at full resolution in the history")
                check((clip.extractedText ?? "").contains("Quarterly"), "with the words in it recognised for search")
                if let fileName = clip.imageFileName { ImageStore.remove(fileName: fileName) }
            } else {
                check(false, "the history clip can be made")
            }

            // Save: the file it writes (the save panel itself needs a person).
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("copywell-save-test.png")
            if let png = CaptureImaging.png(from: image, pointSize: selection.size) {
                try? png.write(to: file, options: .atomic)
                let reread = NSBitmapImageRep(data: (try? Data(contentsOf: file)) ?? Data())
                check(reread?.pixelsWide == image.width, "Save writes a PNG that opens at full resolution")
                try? FileManager.default.removeItem(at: file)
            }

            // Copy Text in Image.
            if let png = CaptureImaging.png(from: image, pointSize: selection.size),
               let text = await OCRService.shared.recognizeText(in: png) {
                check(text.contains("Revenue grew 14%"), "Copy Text finds the words in the picture")
                PasteService.write(.text(text))
                check(pasteboard.string(forType: .string) == text, "and puts them on the clipboard as text")
            } else {
                check(false, "Copy Text finds text")
            }

            print("RESULT: \(failures) failure(s)")
            // The clipboard is restored by the deferred block before exiting.
            let code: Int32 = failures == 0 ? 0 : 1
            DispatchQueue.main.async { exit(code) }
        }
    }

    /// Records a small area of the real screen through the real pipeline —
    /// with the Mac's sound, drawing switched on and off, and a pause in the
    /// middle — then checks the movie, the library, trimming and deleting.
    /// Leaves the clipboard, the settings and Movies ▸ CopyWell as it found them.
    static func testRecording() {
        Task { @MainActor in
            var failures = 0
            @MainActor func check(_ ok: Bool, _ what: String) {
                print((ok ? "PASS  " : "FAIL  ") + what)
                if !ok { failures += 1 }
            }
            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            @MainActor func waitUntilIdle() async {
                for _ in 0..<150 where ScreenRecorder.shared.phase != .idle { await wait(0.1) }
            }
            @MainActor func movies() -> Set<URL> {
                guard let directory = try? RecordingLibrary.directory() else { return [] }
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                return Set(files.filter { $0.pathExtension == "mov" })
            }

            guard CGPreflightScreenCaptureAccess() else {
                print("RESULT: this build has no Screen Recording permission")
                exit(3)
            }
            guard let screen = NSScreen.main else { exit(2) }
            let rect = CGRect(x: screen.frame.width / 2 - 200, y: screen.frame.height / 2 - 150, width: 400, height: 300)
            let recorder = ScreenRecorder.shared
            recorder.diagnosticSystemAudio = true
            let before = movies()

            // 1. Record, draw, pause, resume, stop.
            await recorder.diagnosticStart(screen: screen, rect: rect)
            check(recorder.isRecording, "recording starts")
            guard recorder.isRecording else { exit(1) }
            await wait(1.5)
            recorder.toggleDrawing()
            check(recorder.isDrawing, "drawing on screen switches on")
            recorder.toggleDrawing()
            check(!recorder.isDrawing, "and off again")
            recorder.togglePause()
            check(recorder.isPaused, "pauses")
            let pausedAt = recorder.elapsed(at: Date())
            await wait(2)
            check(abs(recorder.elapsed(at: Date()) - pausedAt) < 0.05, "the clock stands still while paused")
            recorder.togglePause()
            check(!recorder.isPaused, "resumes")
            await wait(1.5)
            let clock = recorder.elapsed(at: Date())
            recorder.stop()
            await waitUntilIdle()
            check(recorder.phase == .idle, "stops")

            guard let url = recorder.diagnosticLastURL, FileManager.default.fileExists(atPath: url.path) else {
                check(false, "a movie was written")
                print("RESULT: \(failures) failure(s)")
                exit(1)
            }
            check(true, "a movie was written to Movies ▸ CopyWell")

            // 2. The movie itself.
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            print("      recorded clock \(String(format: "%.2f", clock)) s, movie \(String(format: "%.2f", duration)) s")
            check(duration > 2.5 && duration < 4, "the movie leaves the pause out (about 3 s, not 5)")
            let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            check(video.count == 1, "one video track")
            if let track = video.first, let size = try? await track.load(.naturalSize) {
                let expected = CGSize(width: 400 * screen.backingScaleFactor, height: 300 * screen.backingScaleFactor)
                print("      frame \(Int(size.width))×\(Int(size.height))")
                check(size == expected, "full-resolution frames of the chosen area")
            }
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            check(audio.count == 1, "one sound track (the Mac's sound)")
            check((try? await asset.load(.isPlayable)) == true, "the movie plays")

            // 3. The library lists it.
            RecordingLibrary.shared.refresh()
            await wait(1.5)
            check(RecordingLibrary.shared.recordings.contains { $0.url == url }, "it appears under Recordings")

            // 4. Trim.
            let trimmed = await RecordingReview.export(url, range: CMTimeRange(
                start: CMTime(seconds: 0.5, preferredTimescale: 600), end: CMTime(seconds: 2, preferredTimescale: 600)))
            let trimmedDuration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            print("      trimmed to \(String(format: "%.2f", trimmedDuration)) s")
            check(trimmed && abs(trimmedDuration - 1.5) < 0.25, "trimming keeps just the chosen part")

            // Pictures of the screens that show recordings, for a look.
            let shots = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            RecordingReview.show(url)
            await wait(1.5)
            if let review = NSApp.windows.first(where: { $0.title == url.deletingPathExtension().lastPathComponent && $0.isVisible }) {
                check(true, "the review window opens")
                // Photographed the way the screen shows it: drawing the view
                // into a bitmap leaves the video layer and the controls blank.
                if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                   let shared = content.windows.first(where: { $0.windowID == CGWindowID(review.windowNumber) }) {
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(review.frame.width * review.backingScaleFactor)
                    configuration.height = Int(review.frame.height * review.backingScaleFactor)
                    if let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: shared), configuration: configuration),
                       let png = CaptureImaging.png(from: image, pointSize: review.frame.size) {
                        try? png.write(to: shots.appendingPathComponent("review-window.png"))
                    }
                }
                review.close()
            } else {
                check(false, "the review window opens")
            }
            let library = NSHostingView(rootView: RecordingsView(searchText: "")
                .frame(width: 820, height: 360)
                .environment(\.colorScheme, .dark))
            library.frame.size = CGSize(width: 820, height: 360)
            library.appearance = NSAppearance(named: .darkAqua)
            await wait(0.5)
            library.layoutSubtreeIfNeeded()
            save(library, to: shots.appendingPathComponent("recordings-view.png"))
            let settings = NSHostingView(rootView: Form { RecordingPresenterSettings() }
                .formStyle(.grouped)
                .frame(width: 640, height: 300)
                .environment(AppSettings.shared)
                .environment(\.colorScheme, .dark))
            settings.frame.size = CGSize(width: 640, height: 300)
            settings.appearance = NSAppearance(named: .darkAqua)
            settings.layoutSubtreeIfNeeded()
            save(settings, to: shots.appendingPathComponent("settings-camera.png"))

            // 5. Delete during a recording leaves nothing behind.
            await recorder.diagnosticStart(screen: screen, rect: rect)
            check(recorder.isRecording, "a second recording starts")
            await wait(1)
            recorder.discard()
            await waitUntilIdle()
            check(movies().subtracting(before).subtracting([url]).isEmpty, "Delete leaves no file behind")

            // 6. One window, as the system picker hands it over.
            let testWindow = NSWindow(contentRect: CGRect(x: 120, y: 160, width: 360, height: 240),
                                      styleMask: [.titled], backing: .buffered, defer: false)
            testWindow.isReleasedWhenClosed = false
            testWindow.title = "CopyWell window test"
            testWindow.sharingType = .readOnly
            testWindow.contentView = NSHostingView(rootView: TimelineView(.animation) { context in
                Text(verbatim: "\(Int(context.date.timeIntervalSinceReferenceDate * 10) % 1000)")
                    .font(.system(size: 60, weight: .bold).monospacedDigit())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            })
            testWindow.orderFrontRegardless()
            await wait(0.8)
            let beforeWindow = movies()
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let shared = content.windows.first(where: { $0.windowID == CGWindowID(testWindow.windowNumber) }) {
                let filter = SCContentFilter(desktopIndependentWindow: shared)
                print("      window content \(NSStringFromRect(filter.contentRect)) × \(filter.pointPixelScale)")
                recorder.diagnosticLastURL = nil
                await recorder.diagnosticStart(filter: filter)
                check(recorder.isRecording, "recording one window starts")
                await wait(2)
                recorder.stop()
                await waitUntilIdle()
                if let windowMovie = recorder.diagnosticLastURL {
                    let windowAsset = AVURLAsset(url: windowMovie)
                    let track = try? await windowAsset.loadTracks(withMediaType: .video).first
                    let size = (try? await track?.load(.naturalSize)) ?? .zero
                    let expected = CGSize(width: Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)) & ~1,
                                          height: Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)) & ~1)
                    print("      window movie \(Int(size.width))×\(Int(size.height))")
                    check(size == expected, "the movie is the window, at full resolution")
                    let windowDuration = (try? await windowAsset.load(.duration).seconds) ?? 0
                    check(windowDuration > 1.5 && windowDuration < 3, "and as long as it was recorded")
                    try? FileManager.default.removeItem(at: windowMovie)
                } else {
                    check(false, "a window movie was written")
                }
            } else {
                check(false, "the test window is visible to ScreenCaptureKit")
            }
            testWindow.close()
            check(movies() == beforeWindow, "no stray files from the window recording")

            // Tidy up: the test's own movie goes.
            try? FileManager.default.removeItem(at: url)
            check(movies() == before, "Movies ▸ CopyWell is as it was")

            print("RESULT: \(failures) failure(s)")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// Puts the click bursts on the real screen, at its centre, a few times,
    /// so they can be photographed mid-flight from outside.
    static func showClicks() {
        guard let screen = NSScreen.main else { exit(2) }
        let ripples = RecordingCanvas(screen: screen, showsClicks: true)
        ripples.show()
        let centre = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        for index in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 0.8) {
                MainActor.assumeIsolated {
                    ripples.burst(at: centre, secondary: index == 4)
                    print("burst \(index) at \(Date().timeIntervalSince1970)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            MainActor.assumeIsolated { ripples.stop(); exit(0) }
        }
    }

    static func run() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { perform() }
        }
    }

    private static func perform() {
        let language = CommandLine.arguments.firstIndex(of: "--language")
            .map { $0 + 1 }
            .flatMap { $0 < CommandLine.arguments.count ? CommandLine.arguments[$0] : nil }
        if let language { LanguageBundle.use(language) }
        let suffix = language.map { "-\($0)" } ?? ""
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let size = CGSize(width: 1440, height: 900)
        guard let picture = syntheticScreen(pixels: CGSize(width: size.width * 2, height: size.height * 2)) else {
            print("RESULT: could not build the synthetic screen"); exit(2)
        }

        // Screenshot mode.
        let state = CaptureToolState()
        state.color = .red
        state.width = .medium
        let (window, view) = host(mode: .screenshot, snapshot: picture, state: state, size: size)
        let session = DiagnosticSession()
        view.delegate = session

        drag(view, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 1000, y: 700))
        print("selection after drag: \(view.selection.map { NSStringFromRect($0) } ?? "nil")")

        state.tool = .arrow
        drag(view, from: CGPoint(x: 420, y: 320), to: CGPoint(x: 640, y: 520))
        state.width = .thick
        drag(view, from: CGPoint(x: 560, y: 360), to: CGPoint(x: 900, y: 330))
        state.width = .thin
        drag(view, from: CGPoint(x: 960, y: 520), to: CGPoint(x: 860, y: 610))
        state.width = .medium
        state.tool = .rectangle
        drag(view, from: CGPoint(x: 660, y: 480), to: CGPoint(x: 900, y: 600))
        state.color = .blue
        state.tool = .ellipse
        drag(view, from: CGPoint(x: 700, y: 300), to: CGPoint(x: 950, y: 420))
        state.color = .yellow
        state.width = .thick
        state.tool = .marker
        drag(view, from: CGPoint(x: 340, y: 640), to: CGPoint(x: 600, y: 640), steps: 12)
        state.color = .green
        state.width = .medium
        state.tool = .pen
        drag(view, from: CGPoint(x: 330, y: 280), to: CGPoint(x: 520, y: 300), steps: 20, wobble: 18)
        state.tool = .pixelate
        drag(view, from: CGPoint(x: 304, y: 574), to: CGPoint(x: 640, y: 606))
        state.color = .red
        state.tool = .text
        click(view, at: CGPoint(x: 330, y: 560))
        if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
            field.stringValue = "Look here"
        } else {
            print("RESULT: text tool made no field")
        }
        state.tool = .line // commits the text
        drag(view, from: CGPoint(x: 310, y: 260), to: CGPoint(x: 990, y: 260))
        // A click without a drag must not leave an invisible mark behind.
        click(view, at: CGPoint(x: 500, y: 500))

        view.layoutSubtreeIfNeeded()
        save(view, to: directory.appendingPathComponent("capture-overlay\(suffix).png"))

        // Tooltips: SwiftUI reports where each control is on the next turn
        // of the run loop, so let it run before asking.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        print("tooltip anchors recorded: \(state.tipFrames.count)")
        state.hoveredTip = CaptureTipTarget(id: "tool.arrow", text: "\(AnnotationTool.arrow.title) (A)", bar: .tools)
        view.tipDidChange(immediately: true)
        save(view, to: directory.appendingPathComponent("capture-tip-tools\(suffix).png"))
        state.hoveredTip = CaptureTipTarget(id: "save", text: L("Save… (⌘S)"), bar: .actions)
        view.tipDidChange(immediately: true)
        save(view, to: directory.appendingPathComponent("capture-tip-actions\(suffix).png"))
        state.hoveredTip = nil
        print("undo enabled: \(state.canUndo)")

        if let result = view.renderSelection() {
            print("result pixels: \(result.width)×\(result.height) (expected 1400×900)")
            if let png = CaptureImaging.png(from: result, pointSize: CGSize(width: 700, height: 450)) {
                try? png.write(to: directory.appendingPathComponent("capture-result\(suffix).png"))
                let rep = NSBitmapImageRep(data: png)
                print("png point size: \(rep.map { NSStringFromSize($0.size) } ?? "?")")
            }
        } else {
            print("RESULT: renderSelection returned nil")
        }

        // ⌘Z the way a real key press arrives: offered to the window as a
        // key equivalent first, where the menu used to swallow it.
        let before = view.annotationCount
        let commandZ = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            // As a Russian layout delivers it: the Z key, typing "я".
            context: nil, characters: "я", charactersIgnoringModifiers: "я", isARepeat: false, keyCode: 6
        )!
        let handled = window.performKeyEquivalent(with: commandZ)
        print("⌘Z handled: \(handled), marks \(before) → \(view.annotationCount)")
        window.orderOut(nil)

        // Recording mode before anything is chosen: the bar sits at the foot.
        let (dockWindow, dockView) = host(mode: .recording, snapshot: nil, state: CaptureToolState(), size: size)
        dockView.layoutSubtreeIfNeeded()
        save(dockView, to: directory.appendingPathComponent("capture-record-docked\(suffix).png"))
        dockWindow.orderOut(nil)

        // Recording mode: no picture, a see-through selection.
        let recordState = CaptureToolState()
        let (recordWindow, recordView) = host(mode: .recording, snapshot: nil, state: recordState, size: size)
        drag(recordView, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 900, y: 650))
        recordView.layoutSubtreeIfNeeded()
        save(recordView, to: directory.appendingPathComponent("capture-record-overlay\(suffix).png"))
        recordWindow.orderOut(nil)

        // The hint shown before anything is selected.
        let (hintWindow, hintView) = host(mode: .screenshot, snapshot: picture, state: CaptureToolState(), size: size)
        save(hintView, to: directory.appendingPathComponent("capture-hint\(suffix).png"))
        hintWindow.orderOut(nil)

        // A click without a drag takes the whole screen.
        let (clickWindow, clickView) = host(mode: .screenshot, snapshot: picture, state: CaptureToolState(), size: size)
        click(clickView, at: CGPoint(x: 700, y: 400))
        print("click-only selection: \(clickView.selection.map { NSStringFromRect($0) } ?? "nil")")
        clickWindow.orderOut(nil)

        // The pieces that appear on their own.
        let controls = NSHostingView(rootView: RecordingControlsView(recorder: ScreenRecorder.shared))
        controls.frame.size = controls.fittingSize
        save(controls, to: directory.appendingPathComponent("capture-recording-controls\(suffix).png"))
        let countdown = NSHostingView(rootView: CountdownView(start: Date().addingTimeInterval(-1.4)) {})
        countdown.frame.size = countdown.fittingSize
        save(countdown, to: directory.appendingPathComponent("capture-countdown\(suffix).png"))

        // History rows, the middle one under the pointer.
        let texts = [
            "• The cleanup now removes only image files, so if the path turns out wrong again, the database and the rest stay",
            "then load everything",
            "• The cleanup now removes only image files, so if the path turns out wrong again, the database and the rest stay",
        ]
        let rows = VStack(spacing: 2) {
            ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                ClipboardItemRow(
                    item: ClipboardItem(contentType: .text, contentHash: "d\(index)", text: text, sourceApp: "CopyWell"),
                    hovered: index == 0,
                    onPaste: {}, onPreview: {}
                )
            }
        }
        .padding(8)
        .frame(width: 760)
        .background(Theme.background)
        .environment(ClipboardStore.shared)
        .environment(\.colorScheme, .dark)
        let rowsView = NSHostingView(rootView: rows)
        rowsView.frame.size = rowsView.fittingSize
        rowsView.appearance = NSAppearance(named: .darkAqua)
        save(rowsView, to: directory.appendingPathComponent("history-rows\(suffix).png"))

        print("RESULT: done, files in \(directory.path)")
        exit(0)
    }

    private static func host(mode: CaptureMode, snapshot: CGImage?, state: CaptureToolState, size: CGSize) -> (NSWindow, CaptureOverlayView) {
        let window = CaptureOverlayWindow(
            contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let view = CaptureOverlayView(frame: CGRect(origin: .zero, size: size), mode: mode, snapshot: snapshot, state: state)
        window.contentView = view
        state.onChange = { view.toolDidChange() }
        state.onTipChange = { view.tipDidChange() }
        window.orderFrontRegardless()
        return (window, view)
    }

    private static func event(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private static func drag(_ view: NSView, from a: CGPoint, to b: CGPoint, steps: Int = 6, wobble: CGFloat = 0) {
        view.mouseDown(with: event(.leftMouseDown, a, in: view))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t + sin(t * .pi * 3) * wobble
            )
            view.mouseDragged(with: event(.leftMouseDragged, point, in: view))
        }
        view.mouseUp(with: event(.leftMouseUp, b, in: view))
    }

    private static func click(_ view: NSView, at point: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, point, in: view))
        view.mouseUp(with: event(.leftMouseUp, point, in: view))
    }

    private static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Something that looks like a screen: a desktop, a window, some text.
    private static func syntheticScreen(pixels: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let colors = [NSColor.systemTeal.cgColor, NSColor.systemIndigo.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: pixels.width, y: pixels.height), options: [])
        }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 260, y: 200, width: 800, height: 540))
        ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 260, y: 712, width: 800, height: 28))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]
        for (index, line) in ["Quarterly report — draft", "Revenue grew 14% on the year.",
                              "Account: 4000 1234 5678 9010", "Password: hunter2", "Contact jane@example.com"].enumerated() {
            NSAttributedString(string: line, attributes: attributes).draw(at: CGPoint(x: 300, y: 660 - CGFloat(index) * 40))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Stands in for `CaptureSession` so key handling can be exercised without
/// putting a real overlay over the screen.
@MainActor
private final class DiagnosticSession: CaptureOverlayDelegate {
    func overlayDidBeginSelection(_ overlay: CaptureOverlayView) {}
    func overlay(_ overlay: CaptureOverlayView, perform action: CaptureAction) {
        if action == .undo { overlay.undo() }
    }
    func overlay(_ overlay: CaptureOverlayView, keyDown event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), event.keyCode == 6 else { return false }
        overlay.undo()
        return true
    }
}
#endif
