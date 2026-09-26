import AppKit
import ScreenCaptureKit

/// The system's own picker for sharing a window or an app — the one video
/// calls use to share a single window.
///
/// macOS draws it and the user picks with it, so CopyWell never has to list,
/// or even see, the other windows on the screen to offer them. It is also the
/// way Apple asks apps to choose what they capture.
@MainActor
final class ContentPicker: NSObject, SCContentSharingPickerObserver {
    private static var current: ContentPicker?
    private var continuation: CheckedContinuation<SCContentFilter?, Never>?

    /// Shows the picker for one window or one app. Returns what was chosen,
    /// or `nil` when the picker was dismissed.
    static func pick(_ style: SCShareableContentStyle) async -> SCContentFilter? {
        current?.finish(nil)
        let picker = ContentPicker()
        current = picker
        return await picker.run(style)
    }

    /// Lets the system know the sharing it offered is over.
    static func endSharing() {
        SCContentSharingPicker.shared.isActive = false
    }

    private func run(_ style: SCShareableContentStyle) async -> SCContentFilter? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let picker = SCContentSharingPicker.shared
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = style == .application ? [.singleApplication] : [.singleWindow]
            // CopyWell's own windows are not something to record.
            if let own = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [own] }
            picker.defaultConfiguration = configuration
            picker.add(self)
            picker.isActive = true
            picker.present(using: style)
        }
    }

    private func finish(_ filter: SCContentFilter?) {
        SCContentSharingPicker.shared.remove(self)
        if filter == nil { SCContentSharingPicker.shared.isActive = false }
        if Self.current === self { Self.current = nil }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: filter)
    }

    // MARK: SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        nonisolated(unsafe) let chosen = filter
        Task { @MainActor in self.finish(chosen) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
