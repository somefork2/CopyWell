import AppKit
import Foundation
import Observation
import StoreKit

/// There is no reduced tier any more: either the trial or a subscription is
/// running and everything works, or CopyWell is locked and does nothing but
/// offer a subscription. Nothing is deleted while it is locked.
enum SubscriptionTier: String, CaseIterable {
    case free, pro
}

enum PremiumFeature: String, CaseIterable, Identifiable {
    case unlimitedHistory
    case unlimitedPinboards
    case pasteStack
    case smartCategorize
    case exportImport
    case cloudSync
    case customShortcuts
    case statistics
    case autoCleanup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimitedHistory: return L("Unlimited History")
        case .unlimitedPinboards: return L("Unlimited Pinboards")
        case .pasteStack: return L("Paste Stack")
        case .smartCategorize: return L("Smart Categorisation")
        case .exportImport: return L("Export")
        case .cloudSync: return L("iCloud Sync")
        case .customShortcuts: return L("Custom Shortcuts")
        case .statistics: return L("Statistics")
        case .autoCleanup: return L("Auto Cleanup")
        }
    }

    var icon: String {
        switch self {
        case .unlimitedHistory: return "clock.arrow.circlepath"
        case .unlimitedPinboards: return "pin"
        case .pasteStack: return "square.stack"
        case .smartCategorize: return "tag"
        case .exportImport: return "square.and.arrow.up"
        case .cloudSync: return "icloud"
        case .customShortcuts: return "command"
        case .statistics: return "chart.bar"
        case .autoCleanup: return "trash"
        }
    }

    /// Plain, checkable claims — every one of these is implemented.
    var summary: String {
        switch self {
        case .unlimitedHistory: return L("Every clip you copy, kept for as long as you want it.")
        case .unlimitedPinboards: return L("Organise clips into as many boards as you need.")
        case .pasteStack: return L("Queue several clips and paste them one after another.")
        case .smartCategorize: return L("On-device analysis tags clips by type, language and entities.")
        case .exportImport: return L("Save your history as JSON, CSV, Markdown or HTML.")
        case .cloudSync: return L("Sync history across your Macs through your private iCloud database.")
        case .customShortcuts: return L("Rebind every global shortcut to whatever you prefer.")
        case .statistics: return L("See what you copy most and from which apps.")
        case .autoCleanup: return L("Automatically remove clips older than a chosen age.")
        }
    }
}

/// StoreKit 2 subscription handling.
///
/// Entitlement is derived from `Transaction.currentEntitlement` on every launch
/// and kept current by the `Transaction.updates` listener, so expiry, refunds
/// and family sharing changes all take effect without a relaunch.
@MainActor
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    static let monthlyID = "com.copywell.pro.monthly"
    static let annualID = "com.copywell.pro.annual"
    static let productIDs = [monthlyID, annualID]

    private(set) var products: [Product] = []
    private(set) var currentTier: SubscriptionTier = .free
    private(set) var activeProductID: String?
    private(set) var expirationDate: Date?
    private(set) var isLoadingProducts = false
    private(set) var purchaseInFlight = false
    private(set) var lastError: String?

    var showingPaywall = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    private init() {}

    #if DEBUG
    /// Unlocks everything in a development build, so the paid experience can be
    /// looked at before the products exist in App Store Connect.
    ///
    /// Compiled out of release entirely: there is no runtime flag, no hidden
    /// preference and no code path in the shipping app that can reach it.
    var simulatedPro: Bool = UserDefaults.standard.bool(forKey: "debug_simulated_pro") {
        didSet { UserDefaults.standard.set(simulatedPro, forKey: "debug_simulated_pro") }
    }

    /// Pins the entitlement for a test.
    ///
    /// The purchase tests and the access tests share one process, and a
    /// `SKTestSession` transaction from the first is visible to the second:
    /// `inState(pro: false)` was reading back `isPro == true` whenever the
    /// order happened to put them that way round. Re-reading the entitlement on
    /// activation and on a timer turned that occasional flake into a frequent
    /// one, which is how it was finally found. Compiled out of release.
    var pinnedTierForTesting: SubscriptionTier? {
        didSet { if let pinnedTierForTesting { currentTier = pinnedTierForTesting } }
    }

    var isPro: Bool { simulatedPro || currentTier == .pro }
    #else
    var isPro: Bool { currentTier == .pro }
    #endif

    /// True while the 30-day trial is running.
    var isInFreeTrial: Bool { TrialManager.shared.isActive }

    #if DEBUG
    /// Forces the locked state for screenshots and manual checks, without
    /// touching the real trial date in the keychain. Release has no such flag.
    var forcedLock = false
    #endif

    /// Everything is unlocked while the trial runs, without anyone having to
    /// subscribe first.
    var hasFullAccess: Bool {
        #if DEBUG
        if forcedLock { return false }
        #endif
        return isPro || isInFreeTrial
    }

    /// True only when the active subscription is still inside its introductory
    /// free-trial period. Never assumed — StoreKit tells us.
    private(set) var isInTrial = false

    func start() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlement()
        }
        watchForExpiry()
    }

    /// Notices a subscription that has simply run out.
    ///
    /// `Transaction.updates` reports purchases, renewals, refunds and
    /// revocations — things that happen. Expiry is not one of them: it is a
    /// date passing, and StoreKit sends nothing. Everywhere else the
    /// entitlement is read is a moment that may never come again in a menu bar
    /// app: launch, a purchase, a restore. One left running for a fortnight
    /// would have kept full access for a fortnight after the subscription
    /// lapsed.
    ///
    /// Re-read when the app is brought to the front, and on a quarter-hour
    /// timer for when it is not. `refreshEntitlement` only reads, so an extra
    /// pass costs nothing when nothing has changed.
    private func watchForExpiry() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await SubscriptionManager.shared.refreshEntitlement() }
        }

        let timer = Timer(timeInterval: 900, repeats: true) { _ in
            Task { @MainActor in await SubscriptionManager.shared.refreshEntitlement() }
        }
        // `.common`, so a menu open or a drag does not hold the check off.
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    deinit {
        updatesTask?.cancel()
        expiryTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    // MARK: - Products

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            // Keep a stable order: monthly first, annual second.
            products = loaded.sorted { lhs, rhs in
                (lhs.id == Self.monthlyID ? 0 : 1) < (rhs.id == Self.monthlyID ? 0 : 1)
            }
            lastError = nil
        } catch {
            products = []
            lastError = L("Could not reach the App Store. Check your connection and try again.")
        }
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    /// Localised price string straight from the App Store — never hard-coded.
    func displayPrice(for id: String) -> String {
        product(for: id)?.displayPrice ?? "—"
    }

    /// Introductory offer description, when the product actually has one.
    func introductoryOffer(for id: String) -> String? {
        guard let offer = product(for: id)?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        // One key per unit, each with plural variations in the catalogue.
        // Injecting a separately translated noun into "%lld %@ free" produced
        // "Осталось 2 дней" and "Pozostało 2 dni" — the number and the noun
        // have to agree, and only the language's own plural rules know how.
        let count = offer.period.value
        switch offer.period.unit {
        case .day: return L("\(count) days free")
        case .week: return L("\(count) weeks free")
        case .month: return L("\(count) months free")
        case .year: return L("\(count) years free")
        @unknown default: return L("\(count) days free")
        }
    }

    /// Savings of the annual plan versus twelve monthly payments, computed from
    /// live App Store prices rather than a hard-coded badge.
    var annualSavingsPercent: Int? {
        guard let monthly = product(for: Self.monthlyID),
              let annual = product(for: Self.annualID) else { return nil }
        let yearlyAtMonthlyRate = monthly.price * Decimal(12)
        guard yearlyAtMonthlyRate > 0, annual.price < yearlyAtMonthlyRate else { return nil }
        let ratio = (yearlyAtMonthlyRate - annual.price) / yearlyAtMonthlyRate
        let percent = NSDecimalNumber(decimal: ratio * Decimal(100)).doubleValue
        return Int(percent.rounded())
    }

    // MARK: - Purchase

    /// What came back from a purchase attempt.
    ///
    /// Returned rather than only left in `lastError` so callers — and tests —
    /// can tell "the customer changed their mind" apart from "the purchase
    /// broke", which look identical when the only signal is an empty error.
    enum PurchaseOutcome: Equatable {
        case purchased
        case cancelled
        case pending
        case unverified
        case unavailable
        case failed(String)
    }

    @discardableResult
    func purchase(_ productID: String) async -> PurchaseOutcome {
        guard let product = product(for: productID) else {
            lastError = L("That plan is unavailable right now.")
            return .unavailable
        }
        purchaseInFlight = true
        defer { purchaseInFlight = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlement(justPurchased: transaction)
                    showingPaywall = false
                    lastError = nil
                    return .purchased
                }
                lastError = L("This purchase could not be verified.")
                return .unverified
            case .userCancelled:
                lastError = nil
                return .cancelled
            case .pending:
                lastError = L("Your purchase is pending approval.")
                return .pending
            @unknown default:
                return .failed("Unknown purchase result.")
            }
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// Required by App Review: users must be able to restore purchases.
    func restorePurchases() async {
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            lastError = isPro ? nil : L("No active subscription was found for this Apple Account.")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showManageSubscriptions() {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Entitlement

    /// Re-reads what the customer is entitled to, straight from StoreKit.
    ///
    /// `justPurchased` is not a convenience. `Transaction.currentEntitlements`
    /// does not reliably include a transaction that was finished a moment ago,
    /// so refreshing immediately after a successful purchase could leave the app
    /// locked until the next launch — money taken, nothing unlocked.
    /// The verified transaction handed to us by `purchase()` is authoritative,
    /// so it is folded in alongside whatever the store reports.
    func refreshEntitlement(justPurchased: StoreKit.Transaction? = nil) async {
        #if DEBUG
        if let pinnedTierForTesting {
            currentTier = pinnedTierForTesting
            return
        }
        #endif
        var tier: SubscriptionTier = .free
        var productID: String?
        var expiry: Date?
        var trial = false

        func consider(_ transaction: StoreKit.Transaction) {
            guard Self.productIDs.contains(transaction.productID) else { return }
            if let revocation = transaction.revocationDate, revocation <= Date() { return }
            if let expiration = transaction.expirationDate, expiration <= Date() { return }

            // Keep the entitlement that runs longest, so an upgrade mid-term is
            // never shortened by an older overlapping one.
            if let current = expiry, let candidate = transaction.expirationDate, candidate <= current {
                return
            }

            tier = .pro
            productID = transaction.productID
            expiry = transaction.expirationDate
            UserDefaults.standard.set(true, forKey: "has_ever_subscribed")
            if #available(macOS 15.0, *) {
                trial = transaction.offer?.type == .introductory
            }
        }

        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            consider(transaction)
        }
        if let justPurchased { consider(justPurchased) }

        currentTier = tier
        activeProductID = productID
        expirationDate = expiry
        isInTrial = trial
    }

    // MARK: - Gating

    func checkAccess(for feature: PremiumFeature) -> Bool { hasFullAccess }

    var statusDescription: String {
        #if DEBUG
        if simulatedPro { return "Pro (simulated for development)" }
        #endif
        if isInTrial { return L("Pro — subscription trial") }
        if isPro { return L("Pro") }
        if isInFreeTrial { return L("Trial — \(TrialManager.shared.daysRemaining) days left") }
        // There is no free tier any more, so "Free" would be a lie: this state
        // is the app locked and waiting for a subscription.
        return L("Locked — subscription needed")
    }

    /// Returns true when the feature may be used; otherwise surfaces the paywall.
    @discardableResult
    func requestAccess(for feature: PremiumFeature) -> Bool {
        if checkAccess(for: feature) { return true }
        showingPaywall = true
        return false
    }

    /// True when neither the trial nor a subscription is running. The app shows
    /// the subscription wall and stops recording; the database is left alone.
    var isLocked: Bool { !hasFullAccess }

    /// Distinguishes "your trial ran out" from "your subscription lapsed", which
    /// are different messages to the same person at different times.
    var hasEverSubscribed: Bool {
        UserDefaults.standard.bool(forKey: "has_ever_subscribed")
    }

    /// Pinboards are unlimited whenever the app is usable at all.
    var pinboardLimit: Int { -1 }
}

