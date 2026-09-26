import Foundation

/// The language CopyWell is showing, changeable while it runs.
///
/// Three approaches were tried and measured before this one:
///
/// * `AppleLanguages` alone — the system reads it at launch, so nothing changed
///   until CopyWell was quit, and it lives in the menu bar and is rarely quit.
/// * Pointing `Bundle.main` at another `.lproj` by swapping its class —
///   `String(localized:)` does not go through the method that intercepts.
/// * The `locale:` argument — it formats interpolations and leaves the table
///   alone. Every language came back with the English string.
///
/// What works is naming the bundle: `String(localized:bundle:)` against a
/// language's own `.lproj` returns that language. So every string in the app
/// goes through `L(_:)`, which passes the bundle currently chosen.
enum LanguageBundle {
    /// Guarded rather than main-actor isolated: `displayName` on the theme and
    /// retention enums is a plain non-isolated property, and hundreds of call
    /// sites like it would otherwise have to become async or main-actor —
    /// a change far larger than the one being made. The lock is uncontended in
    /// practice; only the picker ever writes.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: Bundle = .main
    nonisolated(unsafe) private static var generationStorage = 0

    /// The bundle strings are read from right now.
    static var current: Bundle {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// The locale that goes with the chosen language.
    ///
    /// Strings are only half of it. Dates, relative times and numbers are
    /// formatted by the system against `Locale.current`, which follows the Mac
    /// and not the picker — so a list of clips read "2 ч" under an English
    /// interface until this was passed to every formatter.
    static var locale: Locale {
        lock.lock()
        defer { lock.unlock() }
        guard storage != .main,
              let code = storage.bundlePath.split(separator: "/").last?
                .replacingOccurrences(of: ".lproj", with: "") else { return .current }
        return Locale(identifier: code)
    }

    /// Bumped on every change, so views keyed on it are rebuilt.
    static var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationStorage
    }

    static func use(_ language: String?) {
        let resolved = language.flatMap(bundle(for:)) ?? macLanguageBundle()
        lock.lock()
        defer { lock.unlock() }
        guard resolved != storage else { return }
        storage = resolved
        generationStorage += 1
    }

    /// The bundle for the Mac's own language, for "Same as the Mac".
    ///
    /// Not simply `.main`: after running in German, `.main` *is* German for the
    /// rest of the process, so switching back found nothing to change and the
    /// interface stayed German. The app's own `AppleLanguages` entry has been
    /// removed by the time this runs, so the lookup falls through to the Mac's.
    private static func macLanguageBundle() -> Bundle {
        let preferences = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        let best = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences)
            .first { $0 != "Base" }
        return best.flatMap(bundle(for:)) ?? .main
    }

    /// Falls back from `pt-BR` to `pt` and the other way, so a stored code that
    /// no longer ships exactly still finds the nearest thing.
    private static func bundle(for language: String) -> Bundle? {
        var candidates = [language]
        if let base = language.split(separator: "-").first.map(String.init), base != language {
            candidates.append(base)
        }
        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }
}

/// A localised string in whatever language CopyWell is currently showing.
///
/// Deliberately short: it appears several hundred times, and it has to, because
/// a single `String(localized:)` left behind would stay in the launch language
/// while everything around it changed.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: LanguageBundle.current)
}
