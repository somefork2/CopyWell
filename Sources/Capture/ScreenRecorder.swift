import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit
import SwiftUI

/// Records an area of the screen, or all of it, to a movie in Movies ▸ CopyWell —
/// with the presenter's camera in a bubble and their voice if they want them,
/// a countdown, pause, drawing on screen, and a start-over and a delete that
/// work while it runs.
///
/// CopyWell's own windows — the overlay, the frame round the area, the
/// controls — are left out of the recording by excluding the app as a whole,
/// which ScreenCaptureKit honours even where a window's sharing type is not.
/// The camera bubble and the layer clicks and drawings appear on are let back
/// in by name, because they are there to be seen.
@MainActor
@Observable
final class ScreenRecorder {
    static let shared = ScreenRecorder()

    enum Phase: Equatable {
        case idle
        case choosing
        case preparing
        case countdown
        case recording
        case finishing
    }

    private(set) var phase: Phase = .idle
    private(set) var isPaused = false
    private(set) var isDrawing = false

    /// Recording or paused: a recording is under way.
    var isRecording: Bool { phase == .recording }

    @ObservationIgnored private var accumulated: TimeInterval = 0
    @ObservationIgnored private var segmentStart: Date?
    /// Starts the same recording again, for "Start over": the same area, or
    /// the same window or app.
    @ObservationIgnored private var restart: (() async -> Void)?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var writer: RecordingWriter?
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var chrome: RecordingChrome?
    @ObservationIgnored private var canvas: RecordingCanvas?
    @ObservationIgnored private var camera: CameraBubble?

    private init() {}

    #if DEBUG
    /// Development only: lets the recording diagnostic drive the real
    /// pipeline without touching the clipboard, the user's settings or the
    /// screen beyond the area it records.
    @ObservationIgnored var diagnosticQuiet = false
    /// For the App Store pictures: a clock that reads a chosen time.
    @ObservationIgnored var marketingElapsed: TimeInterval?
    @ObservationIgnored var diagnosticSystemAudio: Bool?
    @ObservationIgnored var diagnosticLastURL: URL?

    func diagnosticStart(screen: NSScreen, rect: CGRect) async {
        diagnosticQuiet = true
        phase = .preparing
        let canvas = RecordingCanvas(screen: screen, showsClicks: true)
        canvas.show()
        self.canvas = canvas
        await start(screen: screen, rect: rect, microphone: false)
    }

    /// The window-or-app path, with the picker's choice made by the test.
    func diagnosticStart(filter: SCContentFilter) async {
        diagnosticQuiet = true
        await prepare(filter: filter)
    }
    #endif

    /// True while a development diagnostic drives the recorder: it must not
    /// count down, open the microphone or change anything of the user's.
    private var isDiagnosing: Bool {
        #if DEBUG
        diagnosticQuiet
        #else
        false
        #endif
    }

    /// Time recorded so far, not counting pauses.
    func elapsed(at now: Date) -> TimeInterval {
        #if DEBUG
        if let marketingElapsed { return marketingElapsed }
        #endif
        return accumulated + (segmentStart.map { now.timeIntervalSince($0) } ?? 0)
    }

    /// The shortcut and the menu item both come here: it starts when idle and
    /// stops when recording, so one key does both.
    func toggle() {
        switch phase {
        case .idle: begin()
        case .recording: stop()
        case .choosing: CaptureSession.cancelCurrent()
        case .countdown: RecordingCountdown.cancelCurrent()
        case .preparing, .finishing: break
        }
    }

    func begin() {
        guard phase == .idle else { return }
        if CaptureSession.current != nil { CaptureSession.cancelCurrent() }
        guard ScreenCaptureAccess.ensure() else { return }
        PasteService.rememberFrontmostApp()
        if QuickPastePanel.shared.isVisible { QuickPastePanel.shared.hide() }

        phase = .choosing
        CaptureSession.present(mode: .recording, snapshots: []) { [weak self] outcome in
            guard let self else { return }
            PasteService.previousApp?.activate()
            switch outcome {
            case .record(let screen, let rect):
                Task { await self.prepare(screen: screen, rect: rect) }
            case .pick(let style):
                Task { await self.pickThenRecord(style) }
            default:
                self.phase = .idle
            }
        }
    }

    // MARK: - Starting

    private func prepare(screen: NSScreen, rect: CGRect) async {
        phase = .preparing
        restart = { [weak self] in await self?.prepare(screen: screen, rect: rect) }
        let settings = AppSettings.shared

        // Camera and microphone are asked for here, the first time a
        // recording that uses them starts — not when the switch is flipped
        // in the toolbar, where the system's question would open behind the
        // overlay. A "no" records without them rather than not at all.
        var useCamera = settings.recordCamera
        if useCamera, !(await MediaAccess.request(.camera)) {
            useCamera = false
            settings.recordCamera = false
        }
        var useMicrophone = settings.recordMicrophone
        if useMicrophone, !(await MediaAccess.request(.microphone)) {
            useMicrophone = false
            settings.recordMicrophone = false
        }

        // The windows that belong in the recording go up first: ScreenCaptureKit
        // can only let back in a window that is on screen when it is asked.
        let canvas = RecordingCanvas(screen: screen, showsClicks: settings.recordShowsClicks)
        canvas.show()
        self.canvas = canvas
        let area = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        if useCamera {
            camera = CameraBubble(deviceID: settings.cameraID, size: settings.cameraSize, over: area, on: screen)
            camera?.show()
        }

        if settings.recordCountdown {
            phase = .countdown
            guard await RecordingCountdown.run(over: area) else {
                tearDown()
                phase = .idle
                return
            }
        }

        await start(screen: screen, rect: rect, microphone: useMicrophone)
    }

    /// A window or an app, chosen in the system's picker.
    private func pickThenRecord(_ style: SCShareableContentStyle) async {
        phase = .preparing
        guard let filter = await ContentPicker.pick(style) else {
            phase = .idle
            return
        }
        await prepare(filter: filter)
    }

    /// Recording one window or one app. The camera bubble and the click
    /// layer are windows of CopyWell's own and cannot be part of another
    /// app's picture, so they are left out; voice and sound are not.
    private func prepare(filter: SCContentFilter) async {
        phase = .preparing
        nonisolated(unsafe) let chosen = filter
        restart = { [weak self] in await self?.prepare(filter: chosen) }
        let settings = AppSettings.shared
        var useMicrophone = settings.recordMicrophone && !isDiagnosing
        if useMicrophone, !(await MediaAccess.request(.microphone)) {
            useMicrophone = false
            settings.recordMicrophone = false
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        if settings.recordCountdown && !isDiagnosing {
            phase = .countdown
            guard await RecordingCountdown.run(over: screen.frame) else {
                tearDown()
                phase = .idle
                return
            }
        }
        phase = .preparing
        do {
            let scale = CGFloat(filter.pointPixelScale)
            let size = filter.contentRect.size
            let width = Self.even(size.width * scale)
            let height = Self.even(size.height * scale)
            try await startStream(filter: filter, configuration: SCStreamConfiguration(),
                                  width: width, height: height, microphone: useMicrophone)
            showChrome(screen: screen, rect: CGRect(origin: .zero, size: screen.frame.size), fullScreen: true)
        } catch {
            fail(error)
        }
    }

    /// An area of a screen, or all of it.
    private func start(screen: NSScreen, rect: CGRect, microphone useMicrophone: Bool) async {
        phase = .preparing
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let id = ScreenCaptureAccess.displayID(of: screen),
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecordingError.displayGone
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ours = content.applications.filter { $0.processID == ownPID }
            let wanted = Set([canvas?.windowID, camera?.windowID].compactMap { $0 })
            let included = content.windows.filter { wanted.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: included)

            let scale = screen.backingScaleFactor
            let screenSize = screen.frame.size
            let fullScreen = rect.width >= screenSize.width - 1 && rect.height >= screenSize.height - 1

            let configuration = SCStreamConfiguration()
            if !fullScreen {
                // ScreenCaptureKit measures from the display's top left, in points.
                configuration.sourceRect = CGRect(
                    x: rect.minX,
                    y: screenSize.height - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
            }
            try await startStream(filter: filter, configuration: configuration,
                                  width: Self.even(rect.width * scale), height: Self.even(rect.height * scale),
                                  microphone: useMicrophone)
            canvas?.start()
            showChrome(screen: screen, rect: rect, fullScreen: fullScreen)
        } catch {
            fail(error)
        }
    }

    /// What every recording shares: the stream, the movie, the voice.
    private func startStream(filter: SCContentFilter, configuration: SCStreamConfiguration,
                             width: Int, height: Int, microphone useMicrophone: Bool) async throws {
        let settings = AppSettings.shared
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = settings.recordShowsPointer
        var systemAudio = settings.recordSystemAudio
        #if DEBUG
        if let forced = diagnosticSystemAudio { systemAudio = forced }
        #endif
        configuration.capturesAudio = systemAudio
        if systemAudio {
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }

        let url = try RecordingLibrary.newRecordingURL()
        let writer = try RecordingWriter(
            url: url, width: width, height: height,
            systemAudio: systemAudio, microphone: useMicrophone
        )
        writer.onStreamStopped = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: writer)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if systemAudio {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        }

        if useMicrophone {
            let microphone = try MicrophoneCapture(deviceID: settings.microphoneID, queue: writer.queue) { [writer] buffer in
                writer.appendMicrophone(buffer)
            }
            await Task.detached { microphone.start() }.value
            self.microphone = microphone
        }

        try await stream.startCapture()

        self.stream = stream
        self.writer = writer
        accumulated = 0
        segmentStart = Date()
        isPaused = false
        isDrawing = false
        phase = .recording
    }

    private func showChrome(screen: NSScreen, rect: CGRect, fullScreen: Bool) {
        let chrome = RecordingChrome(screen: screen, rect: rect, fullScreen: fullScreen, recorder: self)
        chrome.show()
        self.chrome = chrome
    }

    private func fail(_ error: Error) {
        tearDown()
        ContentPicker.endSharing()
        stream = nil
        writer = nil
        phase = .idle
        CaptureFailure.show(error)
    }

    // MARK: - While recording

    func togglePause() {
        guard isRecording, let writer else { return }
        if isPaused {
            segmentStart = Date()
            isPaused = false
        } else {
            accumulated = elapsed(at: Date())
            segmentStart = nil
            isPaused = true
        }
        writer.setPaused(isPaused)
    }

    /// Drawing needs the canvas, which only an area or screen recording has.
    var canDraw: Bool {
        #if DEBUG
        if marketingElapsed != nil { return true }
        #endif
        return canvas != nil
    }

    func toggleDrawing() {
        guard isRecording, let canvas else { return }
        canvas.setDrawing(!canvas.isDrawing)
        isDrawing = canvas.isDrawing
    }

    // MARK: - Ending

    func stop() {
        guard isRecording, let stream, let writer else { return }
        phase = .finishing
        tearDown()
        ContentPicker.endSharing()
        Task { @MainActor in
            try? await stream.stopCapture()
            let url = await writer.finish()
            self.stream = nil
            self.writer = nil
            self.phase = .idle
            if let url {
                await deliver(url)
            } else {
                let alert = NSAlert()
                alert.messageText = L("The recording could not be saved")
                alert.runModal()
            }
        }
    }

    /// Throws the recording away. `thenStartOver` records the same area again
    /// straight away, the way Loom's restart button does.
    func discard(thenStartOver: Bool = false) {
        guard isRecording, let stream, let writer else { return }
        let restart = self.restart
        phase = .finishing
        tearDown()
        Task { @MainActor in
            try? await stream.stopCapture()
            await writer.cancel()
            self.stream = nil
            self.writer = nil
            self.phase = .idle
            #if DEBUG
            if diagnosticQuiet { return }
            #endif
            if thenStartOver, let restart {
                await restart()
            } else {
                ContentPicker.endSharing()
                CaptureToast.show(L("Recording deleted"), symbol: "trash")
                PasteService.previousApp?.activate()
            }
        }
    }

    private func tearDown() {
        chrome?.close()
        chrome = nil
        canvas?.stop()
        canvas = nil
        camera?.close()
        camera = nil
        if let microphone {
            DispatchQueue.global(qos: .utility).async { microphone.stop() }
        }
        microphone = nil
        segmentStart = nil
        isPaused = false
        isDrawing = false
    }

    /// The movie goes onto the clipboard as a file, so it can be pasted
    /// straight into a message or a Finder window, and opens for a look.
    private func deliver(_ url: URL) async {
        // Voice and system sound were written as two tracks; most players
        // only play the first, so they are mixed into one.
        await RecordingMixdown.mixAudioIfNeeded(at: url)
        RecordingLibrary.shared.refresh()
        #if DEBUG
        diagnosticLastURL = url
        if diagnosticQuiet { return }
        #endif

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        PasteboardPrivacy.markAsAutoGenerated(pasteboard)
        SoundPlayer.play(.captured)

        if AppSettings.shared.openRecordingWhenDone {
            RecordingReview.show(url)
        } else {
            CaptureToast.show(
                L("Recording saved to Movies ▸ CopyWell and copied"),
                symbol: "film",
                actionTitle: L("Show in Finder")
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Video encoders want even dimensions.
    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.down)) & ~1)
    }
}

enum RecordingError: LocalizedError {
    case displayGone
    case writer
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .displayGone: return L("The display being recorded is no longer connected.")
        case .writer: return L("The movie file could not be created.")
        case .noMicrophone: return L("The microphone could not be started.")
        }
    }
}

// MARK: - Writing the movie

/// Receives frames and sound on its own queue and writes them to the movie.
///
/// Everything it owns is touched only on `queue` — the queue ScreenCaptureKit
/// and the microphone both deliver on — which is what makes the unchecked
/// `Sendable` true.
final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.copywell.recording", qos: .userInitiated)
    var onStreamStopped: (@Sendable () -> Void)?

    private let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var sessionStarted = false
    private var finished = false

    /// Pausing drops what arrives and, on resume, shifts every later
    /// timestamp back by the length of the pause, so the movie has no gap.
    private var paused = false
    private var pausedAt: CMTime = .invalid
    private var offset: CMTime = .zero

    init(url: URL, width: Int, height: Int, systemAudio recordsSystemAudio: Bool, microphone recordsVoice: Bool) throws {
        self.url = url
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        self.writer = writer

        // H.264 plays everywhere, but stops at 4096 × 2304; a whole 5K or 6K
        // display needs HEVC.
        let fitsH264 = width <= 4096 && height <= 2304
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(6_000_000, min(width * height * 6, 80_000_000)),
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalKey: 120,
        ]
        if fitsH264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: fitsH264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecordingError.writer }
        writer.add(video)

        func audioInput(channels: Int, bitRate: Int) -> AVAssetWriterInput? {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            return input
        }
        systemAudio = recordsSystemAudio ? audioInput(channels: 2, bitRate: 160_000) : nil
        microphone = recordsVoice ? audioInput(channels: 1, bitRate: 96_000) : nil

        super.init()
        guard writer.startWriting() else { throw writer.error ?? RecordingError.writer }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, !paused, sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Idle frames — nothing on screen changed — carry no picture.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  let buffer = retimed(sampleBuffer) else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
                sessionStarted = true
            }
            if video.isReadyForMoreMediaData { video.append(buffer) }
        case .audio:
            guard sessionStarted, let systemAudio, systemAudio.isReadyForMoreMediaData,
                  let buffer = retimed(sampleBuffer) else { return }
            systemAudio.append(buffer)
        default:
            break
        }
    }

    /// Called on `queue` by the microphone.
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard !finished, !paused, sessionStarted, let microphone, microphone.isReadyForMoreMediaData,
              let buffer = retimed(sampleBuffer) else { return }
        microphone.append(buffer)
    }

    func setPaused(_ pause: Bool) {
        queue.async { [self] in
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if pause, !paused {
                paused = true
                pausedAt = now
            } else if !pause, paused {
                if pausedAt.isValid { offset = offset + (now - pausedAt) }
                paused = false
                pausedAt = .invalid
            }
        }
    }

    private func retimed(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        return buffer.shifted(by: CMTimeMultiply(offset, multiplier: -1))
    }

    /// The system can end a recording on its own: the display went away, or
    /// the person used the Stop button macOS shows in the menu bar.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?()
    }

    /// Closes the movie. Returns its location, or `nil` if nothing was written.
    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finished = true
                guard sessionStarted, writer.status == .writing else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: nil)
                    return
                }
                video.markAsFinished()
                systemAudio?.markAsFinished()
                microphone?.markAsFinished()
                // Frames only arrive when the screen changes; ending the
                // session now keeps a still last few seconds in the movie
                // instead of cutting it at the last change. A recording
                // stopped while paused ends where the pause began.
                let end = paused && pausedAt.isValid ? pausedAt : CMClockGetTime(CMClockGetHostTimeClock())
                writer.endSession(atSourceTime: end - offset)
                writer.finishWriting { [self] in
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }

    /// Stops writing and deletes the file.
    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                finished = true
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: url)
                continuation.resume()
            }
        }
    }
}

// MARK: - Countdown

/// Three, two, one over the area about to be recorded — time to take a breath
/// and put the pointer where it should start. Clicking it skips the rest.
@MainActor
final class RecordingCountdown {
    private static var current: RecordingCountdown?
    private var panel: FloatingPanel?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// True when it ran out or was clicked; false when it was cancelled.
    static func run(over area: CGRect) async -> Bool {
        let countdown = RecordingCountdown()
        current = countdown
        defer { current = nil }
        return await countdown.run(over: area)
    }

    static func cancelCurrent() {
        current?.finish(false)
    }

    private func run(over area: CGRect) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let hosting = NSHostingView(rootView: CountdownView(start: Date()) { [weak self] in self?.finish(true) })
            let size = hosting.fittingSize
            let panel = FloatingPanel(
                contentRect: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                    width: size.width, height: size.height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = RecordableWindow.aboveCanvas
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = hosting
            panel.orderFrontRegardless()
            self.panel = panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.finish(true) }
            }
        }
    }

    private func finish(_ proceed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        panel?.orderOut(nil)
        panel = nil
        continuation.resume(returning: proceed)
    }
}

struct CountdownView: View {
    let start: Date
    let onSkip: () -> Void

    @State private var hovered = false

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let number = max(1, 3 - Int(elapsed))
            let progress = min(1, elapsed / 3)
            ZStack {
                Circle().fill(Color.black.opacity(0.72))
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(6)
                Text(verbatim: "\(number)")
                    .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 150, height: 150)
        }
        .contentShape(Circle())
        .scaleEffect(hovered ? 1.05 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSkip)
        .help(L("Click to start now"))
        .padding(10)
    }
}

// MARK: - On-screen chrome while recording

/// A frame round the area being recorded and a small panel with the elapsed
/// time and the controls. Neither appears in the movie.
@MainActor
final class RecordingChrome {
    private let screen: NSScreen
    private let rect: CGRect
    private let fullScreen: Bool
    private let recorder: ScreenRecorder
    private var border: NSWindow?
    private var controls: NSPanel?

    init(screen: NSScreen, rect: CGRect, fullScreen: Bool, recorder: ScreenRecorder) {
        self.screen = screen
        self.rect = rect
        self.fullScreen = fullScreen
        self.recorder = recorder
    }

    func show() {
        let area = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)

        if !fullScreen {
            let window = NSWindow(
                contentRect: area.insetBy(dx: -3, dy: -3),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = RecordingBorderView()
            window.orderFrontRegardless()
            border = window
        }

        let hosting = NSHostingView(rootView: RecordingControlsView(recorder: recorder))
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        var origin: CGPoint
        if fullScreen {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 16)
        } else {
            origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 12)
            if origin.y < visible.minY + 4 { origin.y = area.maxY + 12 }
            if origin.y + size.height > visible.maxY - 4 { origin.y = area.minY + 12 }
        }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)

        let panel = FloatingPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the drawing layer, or Stop could not be pressed while drawing.
        panel.level = RecordableWindow.aboveCanvas
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        controls = panel
    }

    func close() {
        border?.orderOut(nil)
        controls?.orderOut(nil)
        border = nil
        controls = nil
    }
}

private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

enum RecordingClock {
    static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct RecordingControlsView: View {
    let recorder: ScreenRecorder

    var body: some View {
        HStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack(spacing: 7) {
                    if recorder.isPaused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                            .frame(width: 9)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                            .opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.35)
                    }
                    Text(RecordingClock.string(recorder.elapsed(at: context.date)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)

            control(recorder.isPaused ? "play.fill" : "pause.fill",
                    recorder.isPaused ? L("Resume") : L("Pause")) { recorder.togglePause() }
            if recorder.canDraw {
                control("scribble.variable", recorder.isDrawing ? L("Stop drawing") : L("Draw on screen"),
                        isOn: recorder.isDrawing) { recorder.toggleDrawing() }
            }
            control("arrow.counterclockwise", L("Start over")) { recorder.discard(thenStartOver: true) }
            control("trash", L("Delete recording")) { recorder.discard() }

            Button { recorder.stop() } label: {
                Label(L("Stop"), systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.red))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverLift(scale: 1.04))
            .help(L("Stop recording"))
            .padding(.leading, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(white: 0.13).opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func control(_ symbol: String, _ help: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? Color.accentColor : .clear))
        }
        .buttonStyle(.hoverPlate(.white, rest: 0.08, hover: 0.2, press: 0.3, padding: 0, cornerRadius: 7))
        .help(help)
        .accessibilityLabel(help)
    }
}

extension CMSampleBuffer {
    /// The same samples, every timestamp moved by `delta`.
    func shifted(by delta: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + delta
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + delta
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: self,
            sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copy
        )
        return copy
    }
}
