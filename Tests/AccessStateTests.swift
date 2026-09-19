import AppKit
import Foundation
import Testing
@testable import CopyWell

/// What the app actually allows in each of its three states.
///
/// These exist because the gates used to ask `isPro`, which is true only for a
/// paid subscription. During the 30-day trial — the state every new user and
/// every App Review reviewer is in — that reads false, and four paid features
/// were switched off for people who were entitled to all of them.
@Suite("Access in each state", .serialized)
@MainActor
struct AccessStateTests {

    /// Runs `body` with the app in a given state and puts everything back.
    private func inState(pro: Bool, locked: Bool, trialActive: Bool, _ body: () throws -> Void) rethrows {
        let manager = SubscriptionManager.shared
        let trial = TrialManager.shared
        let previousPro = manager.simulatedPro
        let previousLock = manager.forcedLock
        // The start date lives in the keychain, so it has to be restored rather
        // than left wherever the test moved it.
        let previousStart = trial.startDate

        // Pinned, not merely un-simulated: a real `SKTestSession` transaction
        // left by the purchase tests lives in the same process and would
        // otherwise make `currentTier` .pro behind this test's back.
        let previousPin = manager.pinnedTierForTesting
        manager.pinnedTierForTesting = pro ? .pro : .free
        manager.simulatedPro = pro
        manager.forcedLock = locked
        trial.simulateStart(daysAgo: trialActive ? 1 : 40)
        defer {
            manager.pinnedTierForTesting = previousPin
            manager.simulatedPro = previousPro
            manager.forcedLock = previousLock
            trial.simulateStart(daysAgo: Int((Date().timeIntervalSince(previousStart) / 86_400).rounded()))
        }
        try body()
    }

    private func scratchPasteboard(_ name: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("CopyWellTests.\(name)"))
        board.clearContents()
        return board
    }

    // MARK: - The trial

    @Test("The trial unlocks everything, even though nothing has been bought")
    func trialUnlocksEverything() {
        inState(pro: false, locked: false, trialActive: true) {
            let manager = SubscriptionManager.shared

            // The trap: this is false, and every gate that asked it was wrong.
            #expect(manager.isPro == false)

            #expect(manager.isInFreeTrial)
            #expect(manager.hasFullAccess)
            #expect(manager.isLocked == false)

            for feature in PremiumFeature.allCases {
                #expect(manager.checkAccess(for: feature), "\(feature.rawValue) was refused during the trial")
            }
        }
    }

    @Test("The status line names the trial rather than a free plan")
    func trialStatusReadsAsTrial() {
        inState(pro: false, locked: false, trialActive: true) {
            let text = SubscriptionManager.shared.statusDescription
            #expect(text.contains("\(TrialManager.shared.daysRemaining)"))
            #expect(text != String(localized: "Free"))
        }
    }

    // MARK: - Locked

    @Test("A locked app refuses every feature")
    func lockedRefusesEverything() {
        inState(pro: false, locked: true, trialActive: false) {
            let manager = SubscriptionManager.shared
            #expect(manager.hasFullAccess == false)
            #expect(manager.isLocked)
            for feature in PremiumFeature.allCases {
                #expect(manager.checkAccess(for: feature) == false, "\(feature.rawValue) survived the lock")
            }
        }
    }

    @Test("A locked app never calls itself free")
    func lockedStatusIsNotFree() {
        inState(pro: false, locked: true, trialActive: false) {
            let text = SubscriptionManager.shared.statusDescription
            // Compared against the catalogue rather than an English phrase: the
            // app runs in whatever language the machine is set to.
            #expect(text == String(localized: "Locked — subscription needed"))
            #expect(text != String(localized: "Free"))
        }
    }

    // MARK: - Services, which are reachable from every other app

    @Test("Every paste Service is refused while locked")
    func pasteServicesRefuseWhileLocked() {
        inState(pro: false, locked: true, trialActive: false) {
            let provider = ServiceProvider()

            for (name, call) in [
                ("quickPaste", { (b: NSPasteboard, e: AutoreleasingUnsafeMutablePointer<NSString>) in
                    provider.quickPasteFromCopyWell(b, userData: "", error: e) }),
                ("pastePlain", { (b: NSPasteboard, e: AutoreleasingUnsafeMutablePointer<NSString>) in
                    provider.pastePlainFromCopyWell(b, userData: "", error: e) })
            ] {
                let board = scratchPasteboard(name)
                var error: NSString = ""
                call(board, &error)
                #expect(board.string(forType: .string) == nil, "\(name) handed a clip back while locked")
                #expect(error.length > 0, "\(name) refused silently")
            }
        }
    }

    @Test("Text recognition is refused while locked")
    func recognitionRefusedWhileLocked() {
        inState(pro: false, locked: true, trialActive: false) {
            let board = scratchPasteboard("ocr")
            let image = NSImage(size: NSSize(width: 40, height: 20))
            board.clearContents()
            board.writeObjects([image])

            var error: NSString = ""
            ServiceProvider().recognizeTextFromCopyWell(board, userData: "", error: &error)
            #expect(error.length > 0, "OCR ran while the app was locked")
        }
    }

    @Test("A locked app takes nothing in")
    func ingestRefusedWhileLocked() {
        inState(pro: false, locked: true, trialActive: false) {
            let before = ClipboardStore.shared.items.count
            let board = scratchPasteboard("ingest")
            board.clearContents()
            board.setString("something copied while locked", forType: .string)

            var error: NSString = ""
            ServiceProvider().saveSelectionToCopyWell(board, userData: "", error: &error)
            #expect(ClipboardStore.shared.items.count == before, "a clip was recorded while locked")
        }
    }
}

// MARK: - Language

/// Serialized: these tests change the language for the whole process, and one
/// of them reading `Bundle.main` while another had just pointed the process at
/// Russian is how this suite first went red.
@Suite("Language", .serialized)
@MainActor
struct LanguageTests {

    @Test("Every shipped language resolves to a bundle in the app")
    func everyLanguageResolves() {
        for code in AppSettings.availableLanguages where code != "en" {
            let path = Bundle.main.path(forResource: code, ofType: "lproj")
                ?? Bundle.main.path(forResource: String(code.split(separator: "-")[0]), ofType: "lproj")
            #expect(path != nil, "\(code) has no .lproj in the built app")
        }
    }

    @Test("Each language has a name to show in the picker")
    func everyLanguageHasAName() {
        for code in AppSettings.availableLanguages {
            let name = AppSettings.languageName(code)
            #expect(!name.isEmpty)
            #expect(name != code, "\(code) fell back to showing its own code")
        }
    }

    /// The `locale:` argument does not do this: it formats interpolations and
    /// leaves the table alone. Measured — every language came back "Copy".
    /// An explicit bundle is the lever that works.
    private func bundle(_ code: String) -> Bundle? {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    @Test("A language's own bundle returns that language's strings")
    func bundleArgumentSwitchesStrings() throws {
        let en = try #require(bundle("en"))
        let ru = try #require(bundle("ru"))
        let de = try #require(bundle("de"))
        // Named explicitly rather than taken from `Bundle.main`: any test that
        // has already chosen a language moves what main resolves to, and this
        // one then compared Russian against Russian and failed.
        let english = String(localized: "Copy", bundle: en)
        let russian = String(localized: "Copy", bundle: ru)
        let german = String(localized: "Copy", bundle: de)
        #expect(russian != english, "ru bundle returned the English string")
        #expect(german != english, "de bundle returned the English string")
        #expect(russian != german)
    }

    /// The point of the whole mechanism: a language chosen now changes what
    /// `L(_:)` returns now. Relaunching is not an acceptable answer for an app
    /// that lives in the menu bar and is almost never quit.
    @Test("Switching the language changes strings without a relaunch")
    func switchingIsImmediate() {
        let settings = AppSettings.shared
        let before = settings.preferredLanguage
        defer { settings.preferredLanguage = before }

        settings.preferredLanguage = "en"
        let english = L("Copy")
        let generationAfterEnglish = settings.languageGeneration

        settings.preferredLanguage = "ru"
        let russian = L("Copy")

        #expect(russian != english, "the string did not follow the language")
        #expect(settings.languageGeneration != generationAfterEnglish,
                "nothing told the views to rebuild")

        settings.preferredLanguage = "de"
        #expect(L("Copy") != russian)
        #expect(L("Copy") != english)
    }

    /// A code we no longer ship exactly should land on the nearest thing rather
    /// than silently falling back to English.
    @Test("A regional code falls back to its base language")
    func regionalFallback() {
        let settings = AppSettings.shared
        let before = settings.preferredLanguage
        defer { settings.preferredLanguage = before }

        settings.preferredLanguage = "de-AT"
        #expect(LanguageBundle.current != Bundle.main, "de-AT did not reach de")
        #expect(L("Copy") == String(localized: "Copy", bundle: LanguageBundle.current))
    }
}
