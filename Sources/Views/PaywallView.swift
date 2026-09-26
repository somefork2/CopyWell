import StoreKit
import SwiftUI

/// The subscription screen.
///
/// Everything shown here comes from StoreKit: price, currency, billing period
/// and whether an introductory free trial actually exists. App Review requires
/// the period, the price per period, a restore control and links to the privacy
/// policy and terms — all present below.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionManager.self) private var manager

    @State private var selectedProductID = SubscriptionManager.annualID

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            featureList
            Divider()
            plans
            purchaseControls
        }
        .frame(width: 460, height: 660)
        .task {
            if manager.products.isEmpty { await manager.loadProducts() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverIcon)
                .accessibilityLabel(L("Close"))
            }

            Image(systemName: "clipboard")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)

            Text(L("CopyWell Pro"))
                .font(.title2.weight(.semibold))

            Text(L("Everything in CopyWell, for as long as you subscribe."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Features

    private var featureList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(PremiumFeature.allCases) { feature in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: feature.icon)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title)
                                .font(.callout.weight(.medium))
                            Text(feature.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Plans

    @ViewBuilder
    private var plans: some View {
        if manager.isLoadingProducts {
            ProgressView()
                .padding(24)
        } else if manager.products.isEmpty {
            VStack(spacing: 8) {
                Text(manager.lastError ?? L("Plans are unavailable right now."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L("Try Again")) {
                    Task { await manager.loadProducts() }
                }
            }
            .padding(24)
        } else {
            HStack(spacing: 12) {
                ForEach(manager.products, id: \.id) { product in
                    PlanCard(
                        product: product,
                        introOffer: manager.introductoryOffer(for: product.id),
                        savingsBadge: product.id == SubscriptionManager.annualID
                            ? manager.annualSavingsPercent.map { L("Save \($0)%") }
                            : nil,
                        isSelected: selectedProductID == product.id
                    ) {
                        selectedProductID = product.id
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
    }

    // MARK: - Purchase

    private var purchaseControls: some View {
        VStack(spacing: 10) {
            Button {
                Task { await manager.purchase(selectedProductID) }
            } label: {
                Group {
                    if manager.purchaseInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(primaryButtonTitle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(manager.products.isEmpty || manager.purchaseInFlight)

            // Required by App Review: restoring must always be possible.
            Button(L("Restore Purchases")) {
                Task { await manager.restorePurchases() }
            }
            .buttonStyle(.hoverLink)
            .disabled(manager.purchaseInFlight)

            if let error = manager.lastError, !manager.products.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Text(renewalDisclosure)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Link(L("Privacy Policy"), destination: LegalLinks.privacyPolicy)
                Text("·").foregroundStyle(.secondary)
                Link(L("Terms of Use"), destination: LegalLinks.termsOfUse)
                Text("·").foregroundStyle(.secondary)
                Button(L("Manage Subscription")) { manager.showManageSubscriptions() }
                    .buttonStyle(.hoverLink)
            }
            .font(.caption2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var primaryButtonTitle: String {
        guard let product = manager.product(for: selectedProductID) else { return L("Subscribe") }
        if let trial = manager.introductoryOffer(for: product.id) {
            return L("Start \(trial), then \(product.displayPrice)/\(periodName(product))")
        }
        return L("Subscribe — \(product.displayPrice)/\(periodName(product))")
    }

    /// Plain-language renewal terms, stated on the purchase screen itself.
    private var renewalDisclosure: String {
        guard let product = manager.product(for: selectedProductID) else {
            return L("Subscriptions renew automatically until cancelled.")
        }
        let period = periodName(product)
        let trialSentence = manager.introductoryOffer(for: product.id).map {
            L(" The \($0) trial converts to a paid subscription unless cancelled at least 24 hours before it ends.")
        } ?? ""
        return L("\(product.displayPrice) per \(period), billed through your Apple Account and renewed automatically until cancelled.\(trialSentence) Manage or cancel in App Store ▸ Subscriptions.")
    }

    private func periodName(_ product: Product) -> String {
        guard let unit = product.subscription?.subscriptionPeriod.unit else { return L("period") }
        switch unit {
        case .day: return L("day")
        case .week: return L("week")
        case .month: return L("month")
        case .year: return L("year")
        @unknown default: return L("period")
        }
    }
}

struct PlanCard: View {
    let product: Product
    let introOffer: String?
    let savingsBadge: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                if let savingsBadge {
                    Text(savingsBadge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }

                Text(product.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(product.displayPrice)
                    .font(.title.weight(.semibold))

                Text(periodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let introOffer {
                    Text(introOffer)
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.accent.opacity(0.08) : Theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Theme.accent : Theme.separator, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.hoverLift(scale: 1.015))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var periodLabel: String {
        guard let unit = product.subscription?.subscriptionPeriod.unit else { return "" }
        switch unit {
        case .day: return L("per day")
        case .week: return L("per week")
        case .month: return L("per month")
        case .year: return L("per year")
        @unknown default: return ""
        }
    }
}

/// Both links are mandatory on the subscription screen and in App Store Connect,
/// and App Review follows them — a page that 404s is a rejection on its own.
enum LegalLinks {
    static let privacyPolicy = URL(string: "https://somefork2.github.io/CopyWell/privacy.html")!
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let support = URL(string: "https://somefork2.github.io/CopyWell/support.html")!
}
