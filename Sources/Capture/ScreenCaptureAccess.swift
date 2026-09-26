import AppKit
import CoreGraphics
import ScreenCaptureKit

/// The Screen Recording permission, which screenshots and recordings both need.
///
/// It is the only permission CopyWell asks for, and only when one of these two
/// features is first used — the clipboard itself still needs nothing.
@MainActor
enum ScreenCaptureAccess {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// True when capture can go ahead. Otherwise explains what is needed and
    /// offers to open the right pane of System Settings.
    ///
    /// The system's own prompt appears once per install and is easy to dismiss
    /// by accident, after which macOS never shows it again; every later attempt
    /// would fail silently. So our explanation comes first, every time the
    /// permission is missing.
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        NSApp.activate(ignoringOtherApps: true)
        // Turning the switch on is not enough: macOS applies it to a running
        // app only once it is reopened, so the second time round the alert
        // came back although the permission had been given. From then on it
        // says so, and offers the reopen itself.
        let askedBefore = UserDefaults.standard.bool(forKey: "screenCaptureAccessRequested")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Allow CopyWell to see the screen")
        var text = L("Screenshots and screen recordings need the Screen Recording permission. Turn on CopyWell in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording. macOS may ask you to reopen CopyWell afterwards.\n\nThe clipboard history does not need this permission.")
        if askedBefore {
            text += "\n\n" + L("If you have just allowed Screen Recording, macOS applies it only after CopyWell is reopened.")
        }
        alert.informativeText = text
        alert.addButton(withTitle: L("Open System Settings"))
        if askedBefore { alert.addButton(withTitle: L("Reopen CopyWell")) }
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if askedBefore, response == .alertSecondButtonReturn {
            CaptureFailure.relaunch()
            return false
        }
        guard response == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: "screenCaptureAccessRequested")

        // Asking puts CopyWell into the list in System Settings, so there is a
        // switch to turn on — without it the list may not mention us at all.
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(settingsURL)
        }
        return false
    }

    /// The `NSScreen` that goes with a ScreenCaptureKit display.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// A still picture of one screen, taken before the overlay appears.
struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
}

enum ScreenSnapshotter {
    /// Photographs every screen at its full pixel resolution.
    ///
    /// Taken before anything of ours is on screen, so the overlay shows — and
    /// crops — exactly what the user was looking at.
    @MainActor
    static func snapshotAllScreens() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let id = ScreenCaptureAccess.displayID(of: screen),
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let scale = screen.backingScaleFactor
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.colorSpaceName = CGColorSpace.sRGB
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            result.append(ScreenSnapshot(screen: screen, image: image))
        }
        return result
    }
}
