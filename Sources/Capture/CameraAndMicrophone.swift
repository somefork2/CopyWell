import AppKit
import AVFoundation

// MARK: - Permissions

/// Camera and microphone access, asked for at the moment a feature that needs
/// it is switched on — never at launch, and never for someone who only uses
/// the clipboard.
@MainActor
enum MediaAccess {
    enum Kind {
        case camera
        case microphone

        var mediaType: AVMediaType { self == .camera ? .video : .audio }

        var settingsURL: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(self == .camera ? "Privacy_Camera" : "Privacy_Microphone")")!
        }
    }

    static func isAuthorized(_ kind: Kind) -> Bool {
        AVCaptureDevice.authorizationStatus(for: kind.mediaType) == .authorized
    }

    /// True when the feature may use the device. Asks the first time; after a
    /// refusal it explains where the switch is instead of failing silently.
    static func request(_ kind: Kind) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: kind.mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: kind.mediaType)
        default:
            explainRefusal(kind)
            return false
        }
    }

    private static func explainRefusal(_ kind: Kind) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch kind {
        case .camera:
            alert.messageText = L("CopyWell cannot use the camera")
            alert.informativeText = L("To show yourself in a bubble over recordings, turn on CopyWell in System Settings ▸ Privacy & Security ▸ Camera.")
        case .microphone:
            alert.messageText = L("CopyWell cannot use the microphone")
            alert.informativeText = L("To record your voice with the screen, turn on CopyWell in System Settings ▸ Privacy & Security ▸ Microphone.")
        }
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(kind.settingsURL)
        }
    }

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices
    }
}

// MARK: - Windows that belong in the recording

/// CopyWell leaves its own windows out of recordings. These are the exceptions
/// — the camera bubble and the layer the clicks and drawings are shown on —
/// and the window privacy pass leaves them visible to capture.
class RecordableWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Above the canvas the clicks and drawings go on, so the bubble can be
    /// dragged and the Stop button pressed while drawing is on.
    static let aboveCanvas = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let canvas = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
}

// MARK: - Camera bubble

enum CameraBubbleSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var diameter: CGFloat {
        switch self {
        case .small: return 140
        case .medium: return 200
        case .large: return 290
        }
    }

    var title: String {
        switch self {
        case .small: return L("Small")
        case .medium: return L("Medium")
        case .large: return L("Large")
        }
    }
}

private final class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    var onDoubleClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

/// You, in a round window over the recording, the way Loom shows its
/// presenter. Drag it anywhere; double-click or right-click to change its size.
/// It is mirrored, as people expect to see themselves.
@MainActor
final class CameraBubble: NSObject {
    private let session = AVCaptureSession()
    private let window: RecordableWindow
    private let container = DraggableView()
    private let preview: AVCaptureVideoPreviewLayer
    private var size: CameraBubbleSize

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    init?(deviceID: String?, size: CameraBubbleSize, over area: CGRect, on screen: NSScreen) {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.sessionPreset = .high
        session.addInput(input)
        self.size = size

        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        let d = size.diameter
        // Bottom left of the recorded area, where a presenter usually sits and
        // where it covers the least of what is being shown.
        var origin = CGPoint(x: area.minX + 24, y: area.minY + 24)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - d - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - d - 8)

        window = RecordableWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: d, height: d)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = RecordableWindow.aboveCanvas
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.sharingType = .readOnly
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        container.wantsLayer = true
        container.frame = CGRect(x: 0, y: 0, width: d, height: d)
        container.autoresizingMask = [.width, .height]
        container.layer?.cornerRadius = d / 2
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 3
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        container.layer?.backgroundColor = NSColor.black.cgColor
        preview.frame = container.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.layer?.insertSublayer(preview, at: 0)
        container.onDoubleClick = { [weak self] in self?.cycleSize() }
        container.onMenu = { [weak self] event in self?.showMenu(event) }
        window.contentView = container
    }

    func show() {
        window.orderFrontRegardless()
        // AVCaptureSession is documented as safe to start and stop from any
        // thread; it is only not marked Sendable.
        nonisolated(unsafe) let session = self.session
        // startRunning blocks until the camera is up; not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    func close() {
        window.orderOut(nil)
        nonisolated(unsafe) let session = self.session
        DispatchQueue.global(qos: .utility).async { session.stopRunning() }
    }

    private func cycleSize() {
        let all = CameraBubbleSize.allCases
        let next = all[(all.firstIndex(of: size)! + 1) % all.count]
        resize(to: next)
    }

    private func resize(to newSize: CameraBubbleSize) {
        size = newSize
        AppSettings.shared.cameraSize = newSize
        let d = newSize.diameter
        var frame = window.frame
        // Grow round the centre, so the bubble stays where it was put.
        frame = CGRect(x: frame.midX - d / 2, y: frame.midY - d / 2, width: d, height: d)
        window.setFrame(frame, display: true, animate: true)
        container.layer?.cornerRadius = d / 2
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        for option in CameraBubbleSize.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == size ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: container)
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = CameraBubbleSize(rawValue: raw) else { return }
        resize(to: option)
    }
}

// MARK: - Microphone

/// The narrator's voice, delivered as sample buffers on the recording's own
/// queue. Kept apart from ScreenCaptureKit, which only records a microphone
/// from macOS 15 on; this works on every version CopyWell supports.
///
/// A capture session may keep time by the audio device's own clock, while
/// the screen's frames are stamped with the host's. Each buffer is moved onto
/// the host clock before it is handed over, or the voice would drift away
/// from the picture it was describing.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let onSample: @Sendable (CMSampleBuffer) -> Void

    init(deviceID: String?, queue: DispatchQueue, onSample: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        self.onSample = onSample
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecordingError.noMicrophone }
        let input = try AVCaptureDeviceInput(device: device)
        super.init()
        guard session.canAddInput(input), session.canAddOutput(output) else { throw RecordingError.noMicrophone }
        session.addInput(input)
        session.addOutput(output)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start() { session.startRunning() }
    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else {
            onSample(sampleBuffer)
            return
        }
        let stamp = sampleBuffer.presentationTimeStamp
        let host = CMSyncConvertTime(stamp, from: clock, to: CMClockGetHostTimeClock())
        let delta = host - stamp
        guard abs(delta.seconds) > 0.0005, let moved = sampleBuffer.shifted(by: delta) else {
            onSample(sampleBuffer)
            return
        }
        onSample(moved)
    }
}
