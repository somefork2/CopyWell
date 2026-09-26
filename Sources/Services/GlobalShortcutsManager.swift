import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

/// Registers the app's global hotkeys.
///
/// The previous implementation installed a fresh Carbon event handler for every
/// hotkey (so each press fired N times) and kept a single `EventHotKeyRef`, so
/// all but the last binding leaked. Here the handler is installed exactly once
/// and every registration is tracked by its action.
@MainActor
@Observable
final class GlobalShortcutsManager {
    static let shared = GlobalShortcutsManager()

    private(set) var bindings: [ShortcutAction: ClipShortcut] = [:]
    /// Actions whose binding is already taken by another app.
    private(set) var conflicts: Set<ShortcutAction> = []

    @ObservationIgnored private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var handlers: [ShortcutAction: () -> Void] = [:]

    private static let signature = OSType(0x43535041) // 'CSPA'

    private init() {
        loadBindings()
    }

    // MARK: - Public API

    func setHandler(for action: ShortcutAction, _ handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    func registerAll() {
        installHandlerIfNeeded()
        conflicts.removeAll()
        for action in ShortcutAction.allCases {
            register(action)
        }
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    func shortcut(for action: ShortcutAction) -> ClipShortcut {
        bindings[action] ?? action.defaultShortcut
    }

    /// Rebinds an action. Returns `false` when the shortcut is already used by
    /// another action or rejected by the system.
    @discardableResult
    func rebind(_ action: ShortcutAction, to shortcut: ClipShortcut) -> Bool {
        if !shortcut.isEmpty {
            guard shortcut.isValidGlobalBinding else { return false }
            let clash = bindings.first { $0.key != action && $0.value == shortcut }
            if clash != nil { return false }
        }
        bindings[action] = shortcut
        saveBindings()
        unregister(action)
        return register(action)
    }

    func resetToDefaults() {
        bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        saveBindings()
        for action in ShortcutAction.allCases { unregister(action) }
        registerAll()
    }

    // MARK: - Registration

    @discardableResult
    private func register(_ action: ShortcutAction) -> Bool {
        let shortcut = self.shortcut(for: action)
        // A cleared binding cannot clash with anything; without this its old
        // conflict stayed flagged after the shortcut was removed.
        guard !shortcut.isEmpty, shortcut.isValidGlobalBinding else {
            conflicts.remove(action)
            return true
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            conflicts.insert(action)
            return false
        }
        conflicts.remove(action)
        refs[action] = ref
        return true
    }

    private func unregister(_ action: ShortcutAction) {
        if let ref = refs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalShortcutsManager.signature else {
                    return noErr
                }
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    GlobalShortcutsManager.shared.fire(hotKeyID: id)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }

    private func fire(hotKeyID: UInt32) {
        guard let action = ShortcutAction.allCases.first(where: { $0.hotKeyID == hotKeyID }) else { return }
        handlers[action]?()
    }

    // MARK: - Persistence

    private func loadBindings() {
        guard let data = UserDefaults.standard.data(forKey: "shortcut_bindings"),
              let decoded = try? JSONDecoder().decode([String: ClipShortcut].self, from: data) else {
            bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
            return
        }
        for action in ShortcutAction.allCases {
            bindings[action] = decoded[action.rawValue] ?? action.defaultShortcut
        }
    }

    private func saveBindings() {
        let encodable = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: "shortcut_bindings")
        }
    }
}
