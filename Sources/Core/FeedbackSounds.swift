import AppKit
import Foundation

/// Optional sound feedback.
///
/// Off after installation: a utility that lives in the background and makes a
/// noise every time anything is copied is the kind of thing people uninstall.
enum FeedbackSound: String, CaseIterable, Identifiable, Codable {
    case none
    case tink
    case pop
    case morse
    case submarine
    case bottle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return L("None")
        case .tink: return "Tink"
        case .pop: return "Pop"
        case .morse: return "Morse"
        case .submarine: return "Submarine"
        case .bottle: return "Bottle"
        }
    }

    /// Names of sounds macOS ships with, so nothing has to be bundled.
    private var systemName: String? {
        switch self {
        case .none: return nil
        case .tink: return "Tink"
        case .pop: return "Pop"
        case .morse: return "Morse"
        case .submarine: return "Submarine"
        case .bottle: return "Bottle"
        }
    }

    func play() {
        guard let systemName, let sound = NSSound(named: systemName) else { return }
        // Stop first: copying several things quickly should not stack sounds.
        sound.stop()
        sound.play()
    }
}

/// The events a sound can be attached to.
enum SoundEvent {
    case captured
    case pasted

    var settingKey: String {
        switch self {
        case .captured: return "sound_captured"
        case .pasted: return "sound_pasted"
        }
    }
}

@MainActor
enum SoundPlayer {
    static func play(_ event: SoundEvent) {
        let settings = AppSettings.shared
        guard settings.soundsEnabled else { return }
        switch event {
        case .captured: settings.captureSound.play()
        case .pasted: settings.pasteSound.play()
        }
    }
}
