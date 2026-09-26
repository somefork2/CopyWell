import AppKit
import Carbon.HIToolbox
import Foundation

/// A user-remappable global hotkey.
struct ClipShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32

    var isEmpty: Bool { keyCode == 0 && modifiers == 0 }
    static let none = ClipShortcut(keyCode: 0, modifiers: 0)

    var displayString: String {
        guard !isEmpty else { return "—" }
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return L("Space"); case kVK_Return: return "↩"; case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"; case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
        case kVK_ANSI_Grave: return "`"; case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="; case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"; case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"; case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","; case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        default: return L("Key \(keyCode)")
        }
    }

    /// Converts `NSEvent` modifier flags into the Carbon mask Carbon hotkeys need.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    /// A binding is only safe as a global hotkey when it carries a non-shift modifier,
    /// otherwise it swallows ordinary typing system-wide.
    var isValidGlobalBinding: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }
}

/// Every global action the app exposes, with its default binding.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case quickPaste
    case pastePrevious
    case pastePlainText
    case pinLast
    case togglePause
    case pasteStackNext
    // Appended, never inserted: the Carbon hotkey id is the case's position,
    // and moving an existing case would hand its id to another action.
    case captureScreenshot
    case recordScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickPaste: return L("Open Clipboard Palette")
        case .pastePrevious: return L("Copy Previous Item")
        case .pastePlainText: return L("Copy Latest as Plain Text")
        case .pinLast: return L("Pin Last Copied Item")
        case .togglePause: return L("Pause / Resume Recording")
        case .pasteStackNext: return L("Copy Next from Stack")
        case .captureScreenshot: return L("Capture Area")
        case .recordScreen: return L("Record Screen")
        }
    }

    var subtitle: String {
        switch self {
        case .quickPaste: return L("Floating palette at the cursor; pick a clip and press ⌘V")
        case .pastePrevious: return L("Put the item copied before the current one back on the clipboard")
        case .pastePlainText: return L("Put the latest clip on the clipboard with formatting stripped")
        case .pinLast: return L("Add the most recent clip to Favourites")
        case .togglePause: return L("Stop recording clipboard activity")
        case .pasteStackNext: return L("Put the next queued item on the clipboard")
        case .captureScreenshot: return L("Select part of the screen, mark it up, copy or save it")
        case .recordScreen: return L("Record an area or the whole screen; press again to stop")
        }
    }

    var defaultShortcut: ClipShortcut {
        switch self {
        case .quickPaste:
            return ClipShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey))
        case .pastePrevious:
            // Not ⇧⌘V: that is "Paste and Match Style" in the Edit menu of
            // practically every Mac app, and a global hotkey would take it away
            // everywhere. ⌃⌘V is free.
            return ClipShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | cmdKey))
        case .pastePlainText:
            return ClipShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey | cmdKey))
        case .pinLast:
            return ClipShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey))
        case .togglePause:
            return ClipShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey))
        case .pasteStackNext:
            return ClipShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | cmdKey))
        case .captureScreenshot:
            // ⇧⌘9 is what Lightshot uses on the Mac, so people coming from it
            // already have it in their fingers. ⇧⌘3–⇧⌘6 belong to macOS, and
            // ⌥⌘1–⌥⌘5 are Xcode's inspectors.
            return ClipShortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(shiftKey | cmdKey))
        case .recordScreen:
            return ClipShortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(shiftKey | cmdKey))
        }
    }

    /// Carbon hotkey ids must be stable and non-zero.
    var hotKeyID: UInt32 {
        UInt32(ShortcutAction.allCases.firstIndex(of: self)! + 1)
    }
}
