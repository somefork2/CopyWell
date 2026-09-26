import AppKit
import Foundation
import Observation
import ServiceManagement

/// Single source of truth for user preferences.
///
/// Previously every toggle was an isolated `@AppStorage` in `SettingsView` that
/// nothing ever read. Each property here is wired to the behaviour it promises.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }
    var showInDock: Bool { didSet { persist(); applyActivationPolicy() } }
    var showInMenuBar: Bool {
        didSet {
            // With no Dock icon either, the app would have no way back in
            // until it was relaunched — the footer under this switch promises
            // that cannot happen, so the switch refuses.
            if !showInMenuBar && !showInDock { showInMenuBar = true }
            persist()
        }
    }
    var skipPasswords: Bool { didSet { persist() } }
    var skipConcealedPasteboard: Bool { didSet { persist() } }
    var hideFromScreenCapture: Bool { didSet { persist(); NotificationCenter.default.post(name: .copyWellWindowPrivacyChanged, object: nil) } }
    var retention: RetentionPolicy { didSet { retention.save(); ClipboardStore.shared.enforceLimits() } }
    var textSize: TextSizePreference { didSet { persist() } }
    var iCloudSync: Bool { didSet { persist() } }
    /// Off after installation on purpose.
    var soundsEnabled: Bool { didSet { persist() } }
    var captureSound: FeedbackSound { didSet { persist() } }
    var pasteSound: FeedbackSound { didSet { persist() } }
    var hasCompletedOnboarding: Bool { didSet { persist() } }
    /// Recordings take the Mac's own sound along when this is on. Off by
    /// default: a notification chime in a screen recording is rarely wanted.
    var recordSystemAudio: Bool { didSet { persist() } }
    var recordShowsPointer: Bool { didSet { persist() } }
    /// Draws a burst round the pointer on every click in a recording.
    var recordShowsClicks: Bool { didSet { persist() } }
    /// The camera in a round bubble over the recording. Off until someone
    /// turns it on, and only then is the camera permission asked for.
    var recordCamera: Bool { didSet { persist() } }
    var cameraID: String? { didSet { persist() } }
    var cameraSize: CameraBubbleSize { didSet { persist() } }
    /// The narrator's voice. Same rule: off, and asked for only when turned on.
    var recordMicrophone: Bool { didSet { persist() } }
    var microphoneID: String? { didSet { persist() } }
    var recordCountdown: Bool { didSet { persist() } }
    /// Opens the finished recording for a look, a trim or captions.
    var openRecordingWhenDone: Bool { didSet { persist() } }

    /// The language CopyWell runs in, or `nil` to follow the Mac.
    ///
    /// Kept under our own key, and `AppleLanguages` is written as a consequence
    /// — not read back as the answer. macOS writes the resolved language into
    /// every app's container itself, as `ru-RU` rather than `ru`, so reading it
    /// meant mistaking the system's own bookkeeping for a choice someone made,
    /// and matching it against a list of plain codes found nothing: the picker
    /// came up blank.
    ///
    /// The change lands at once: `LanguageBundle` starts reading from that
    /// language's own `.lproj`, `languageGeneration` moves, and the scenes
    /// keyed on it rebuild. `AppleLanguages` is written too, so anything the
    /// system draws for us — the standard menus, open and save panels — comes
    /// up in the same language on the next launch.
    var preferredLanguage: String? {
        didSet {
            guard preferredLanguage != oldValue else { return }
            if let preferredLanguage {
                defaults.set([preferredLanguage], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
            LanguageBundle.use(preferredLanguage)
            languageGeneration = LanguageBundle.generation
            persist()
        }
    }

    /// Moves whenever the language does. Views carry it as their `id`, so
    /// SwiftUI throws the old tree away and runs every `body` again — which is
    /// what makes the new language appear without a relaunch.
    ///
    /// It exists separately from `LanguageBundle.generation` because only a
    /// property of an `@Observable` is watched; a static on an enum is not.
    private(set) var languageGeneration = 0

    /// The language actually in use, for showing what "same as the Mac" means.
    static var effectiveLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
        return languageName(code)
    }

    /// The languages CopyWell is translated into, in the Mac's own naming.
    static let availableLanguages: [String] = [
        "en", "ar", "bn", "ca", "cs", "da", "de", "el", "es", "fi", "fr", "gu",
        "he", "hi", "hr", "hu", "id", "it", "ja", "kn", "ko", "ml", "mr", "ms",
        "nb", "nl", "or", "pa", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sl",
        "sv", "ta", "te", "th", "tr", "uk", "ur", "vi", "zh-Hans", "zh-Hant",
    ]

    /// A language's name in that language, which is how people recognise it.
    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    private init() {
        defaults.register(defaults: [
            // Off by default: this is a menu bar utility. It is reached from
            // the strip at the top of the screen and from its shortcut, and a
            // Dock tile for it only takes up room. Switch it on in Settings ▸
            // General if you would rather have one.
            "showInDock": false,
            "showInMenuBar": true,
            "skipPasswords": true,
            "skipConcealedPasteboard": true,
            "hideFromScreenCapture": true,
            "icloudSync": false,
            "recordSystemAudio": false,
            "recordShowsPointer": true,
            "recordShowsClicks": true,
            "recordCamera": false,
            "recordMicrophone": false,
            "recordCountdown": true,
            "openRecordingWhenDone": true,
        ])

        launchAtLogin = SMAppService.mainApp.status == .enabled
        showInDock = defaults.bool(forKey: "showInDock")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        skipPasswords = defaults.bool(forKey: "skipPasswords")
        skipConcealedPasteboard = defaults.bool(forKey: "skipConcealedPasteboard")
        hideFromScreenCapture = defaults.bool(forKey: "hideFromScreenCapture")
        retention = RetentionPolicy.load()
        textSize = defaults.string(forKey: "textSize")
            .flatMap(TextSizePreference.init(rawValue:)) ?? .standard
        iCloudSync = defaults.bool(forKey: "icloudSync")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        captureSound = defaults.string(forKey: "sound_captured")
            .flatMap(FeedbackSound.init(rawValue:)) ?? .tink
        pasteSound = defaults.string(forKey: "sound_pasted")
            .flatMap(FeedbackSound.init(rawValue:)) ?? .pop
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        recordSystemAudio = defaults.bool(forKey: "recordSystemAudio")
        recordShowsPointer = defaults.bool(forKey: "recordShowsPointer")
        recordShowsClicks = defaults.bool(forKey: "recordShowsClicks")
        recordCamera = defaults.bool(forKey: "recordCamera")
        cameraID = defaults.string(forKey: "cameraID")
        cameraSize = defaults.string(forKey: "cameraSize").flatMap(CameraBubbleSize.init(rawValue:)) ?? .medium
        recordMicrophone = defaults.bool(forKey: "recordMicrophone")
        microphoneID = defaults.string(forKey: "microphoneID")
        recordCountdown = defaults.bool(forKey: "recordCountdown")
        openRecordingWhenDone = defaults.bool(forKey: "openRecordingWhenDone")
        preferredLanguage = defaults.string(forKey: "preferred_language")
    }

    private func persist() {
        defaults.set(showInDock, forKey: "showInDock")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        defaults.set(skipPasswords, forKey: "skipPasswords")
        defaults.set(skipConcealedPasteboard, forKey: "skipConcealedPasteboard")
        defaults.set(hideFromScreenCapture, forKey: "hideFromScreenCapture")
        defaults.set(textSize.rawValue, forKey: "textSize")
        defaults.set(iCloudSync, forKey: "icloudSync")
        defaults.set(soundsEnabled, forKey: "soundsEnabled")
        defaults.set(captureSound.rawValue, forKey: SoundEvent.captured.settingKey)
        defaults.set(pasteSound.rawValue, forKey: SoundEvent.pasted.settingKey)
        defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        defaults.set(recordSystemAudio, forKey: "recordSystemAudio")
        defaults.set(recordShowsPointer, forKey: "recordShowsPointer")
        defaults.set(recordShowsClicks, forKey: "recordShowsClicks")
        defaults.set(recordCamera, forKey: "recordCamera")
        defaults.set(cameraID, forKey: "cameraID")
        defaults.set(cameraSize.rawValue, forKey: "cameraSize")
        defaults.set(recordMicrophone, forKey: "recordMicrophone")
        defaults.set(microphoneID, forKey: "microphoneID")
        defaults.set(recordCountdown, forKey: "recordCountdown")
        defaults.set(openRecordingWhenDone, forKey: "openRecordingWhenDone")
        if let preferredLanguage {
            defaults.set(preferredLanguage, forKey: "preferred_language")
        } else {
            defaults.removeObject(forKey: "preferred_language")
        }
    }

    func applyActivationPolicy() {
        // Keep at least one way to reach the app: if the Dock icon is hidden the
        // menu bar item has to stay.
        if !showInDock && !showInMenuBar {
            showInMenuBar = true
        }
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Registration fails when the app runs outside /Applications; reflect reality.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

extension Notification.Name {
    static let copyWellWindowPrivacyChanged = Notification.Name("copyWellWindowPrivacyChanged")
}
