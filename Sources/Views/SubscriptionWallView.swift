import SwiftUI

/// Shown in place of the app once the trial or the subscription has ended.
///
/// CopyWell stops recording and stops handing clips back, but it does not
/// delete anything: the history stays on disk and reappears the moment a
/// subscription is active. Saying so here is not sentiment — someone who fears
/// their clips are gone asks for a refund instead of subscribing.
struct SubscriptionWallView: View {
    @Environment(SubscriptionManager.self) private var subscriptions

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 18) {
                Image(systemName: "lock")
                    .font(.system(size: 42))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(L("Subscribe to carry on using CopyWell. Nothing has been deleted — your history comes back the moment a subscription is active."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }

                VStack(spacing: 10) {
                    Button(L("See CopyWell Pro")) { subscriptions.showingPaywall = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                    Button(L("Restore Purchases")) {
                        Task { await subscriptions.restorePurchases() }
                    }
                    .buttonStyle(.hoverLink)
                    .disabled(subscriptions.purchaseInFlight)
                }

                if let error = subscriptions.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }

                Label(L("Nothing new is recorded while CopyWell is locked."), systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(40)

            Spacer(minLength: 0)
        }
        // An ideal size as well as a maximum: in the main window the wall fills
        // whatever it is given, but in the menu bar popover there is nothing to
        // fill, and a view that only says "as big as possible" collapses.
        .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity,
               minHeight: 300, idealHeight: 420, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var title: String {
        subscriptions.hasEverSubscribed
            ? L("Your subscription has ended.")
            : L("Your free trial has ended.")
    }
}

/// Puts the wall over whatever the app would otherwise show.
struct SubscriptionGate<Content: View>: View {
    @Environment(SubscriptionManager.self) private var subscriptions
    @ViewBuilder let content: () -> Content

    var body: some View {
        if subscriptions.hasFullAccess {
            content()
        } else {
            SubscriptionWallView()
        }
    }
}
