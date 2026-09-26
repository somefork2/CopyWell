# Mac App Store release checklist

What the code now does, and what only you can do. Everything under "Still yours"
requires an Apple Developer account, a domain, or a decision — none of it can be
committed to the repository.

## Done in this repository

- Xcode project (`project.yml` → `xcodegen generate`) with App Sandbox, Hardened
  Runtime and automatic signing. The Swift package alone can never produce an
  App Store binary.
- `Sources/Resources/CopyWell.entitlements`: sandbox, network client (StoreKit),
  user-selected files, CloudKit container, keychain group.
- `Sources/Resources/PrivacyInfo.xcprivacy`: required-reason declarations for
  `UserDefaults`, file timestamps and disk space. Without this the upload is
  rejected automatically.
- `Info.plist`: `LSApplicationCategoryType`, copyright, `ITSAppUsesNonExemptEncryption`,
  icon name, Services entries.
- App icon at all ten required sizes (`Tools/make-icon.swift` regenerates it).
- StoreKit 2: real products, real prices, `Transaction.updates` listener,
  entitlement derived from `Transaction.currentEntitlement`, **Restore Purchases**,
  manage-subscription link, renewal terms and legal links on the purchase screen.
- `Products.storekit` wired to the Run scheme for local testing.
- Every feature advertised on the paywall is implemented. Nothing is sold that
  does not work.

## Submission status — 19 September 2026

Everything below is done and verified in App Store Connect for version 1.0
(build 2, App ID 6813555231).

- Build 2 uploaded and attached, containing all 33 languages.
- 34 store localisations, each with description, keywords, promotional text,
  support and marketing URLs, and four 2880x1800 screenshots.
- Subtitle, categories (Productivity / Utilities), copyright, age rating.
- App Privacy published as **Data Not Collected**.
- Privacy policy, support and terms pages live at
  https://somefork2.github.io/CopyWell/
- App price set to free; CopyWell Pro at 2.99/24.99 USD in high-income
  territories and 0.99/7.99 USD equivalents everywhere else.
- Access is all or nothing: the 30-day trial and a subscription unlock
  everything, and without either the app locks rather than degrading. Nothing
  is deleted while it is locked.
- Content rights declared; subscription review screenshot attached to both
  products.

**One field is left, and only you can fill it.** App Store Connect refuses to
open a review submission until *App Review Information > Contact Information*
is complete, and it requires a phone number, which is yours to give. Open the
version page, type your name, phone and email under "Контактная информация",
paste the reviewer notes from `docs/review-notes.txt`, leave "sign-in
required" unticked, press Save, then **Add for Review**.

## Still yours

### 1. Identifiers and signing

The Finder extension is a second target and needs its own App ID
(`com.copywell.app.finder`). macOS refuses to load a Finder extension that is
not signed with a development certificate, so it cannot be verified at all
until `DEVELOPMENT_TEAM` is set — plan to test it as the first thing after
signing works.


- [ ] Set `DEVELOPMENT_TEAM` in `project.yml`.
- [ ] Change `PRODUCT_BUNDLE_IDENTIFIER` from `com.copywell.app` to your own
      reverse-domain identifier, then regenerate the project.
- [ ] Register the App ID with App Sandbox, iCloud and In-App Purchase enabled.
- [ ] Turn on the iCloud capability with CloudKit in Xcode (Signing &
      Capabilities ▸ + Capability ▸ iCloud ▸ CloudKit) and let it create the
      container `iCloud.<your bundle id>`. That is the whole CloudKit setup.

      **No schema work is needed.** Sync uses a custom record zone and server
      change tokens rather than queries, so there are no record types, fields or
      indexes to define in the CloudKit console. The zone, the record type and
      its fields are created automatically the first time the app saves a clip.

- [ ] Before submitting, run the app once while signed into iCloud so the schema
      exists in the Development environment, then open the CloudKit console and
      press **Deploy Schema Changes** to copy it to Production. Development and
      Production are separate databases, and the App Store build only ever talks
      to Production. This is one button; it is the only console step.

### 2. In-app purchases

- [ ] Create the subscription group **CopyWell Pro** with
      `com.copywell.pro.monthly` and `com.copywell.pro.annual`
      (rename to match your bundle prefix and update `SubscriptionManager`).
- [ ] Add an introductory free trial if you want one. The UI shows a trial only
      when StoreKit reports one — it never claims a trial that does not exist.
- [ ] Fill in localised display names and descriptions; the paywall renders them.
- [ ] Upload a subscription review screenshot and a review note explaining how to
      reach the paywall.

### 3. Legal (blocking)

- [ ] Host a privacy policy and put its URL in `LegalLinks.privacyPolicy`
      (`Sources/Views/PaywallView.swift`) **and** in App Store Connect.
- [ ] Terms of use: the standard Apple EULA is already linked; replace it if you
      use your own.
- [ ] Host a support page and set `LegalLinks.support`.
- [ ] App Privacy questionnaire: CopyWell collects nothing. Clipboard contents
      stay on device, or in the user's own private CloudKit database. Say exactly
      that.

### 4. Review notes to include

The clipboard requests no privacy-protected data, which removes the usual
reason clipboard utilities get rejected. Screen Recording is asked for only by
the screenshot and screen recording features, on first use. Say so plainly
(docs/review-notes.txt has the full text):

> CopyWell does not request Accessibility or Automation. It never synthesises
> keystrokes: selecting a clip places it on the system pasteboard and the user
> presses ⌘V. Optional insertion without a keypress is provided through a
> standard macOS Service. Screen Recording is requested only when the user first
> takes a screenshot (⇧⌘9) or records the screen (⇧⌘0).

Also mention that the Services entries appear under the Services submenu and how
to enable them in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services.

### 5. Store listing

- [ ] Screenshots at 2880×1800 (the palette, the history window, the menu bar,
      the paywall).
- [ ] Description that matches the feature list exactly — mismatches are the most
      common rejection for subscription apps.
- [ ] Keywords, support URL, marketing URL.
- [ ] Age rating, export compliance (already declared exempt in `Info.plist`).

## Testing before submission

- [ ] Purchase, cancel, expire and restore against `Products.storekit`.
- [ ] Sandbox account purchase on a clean machine.
- [ ] Launch with Accessibility denied: pasting must degrade to "copied to
      clipboard", never fail silently.
- [ ] Launch with no iCloud account: sync must report it, not hang.
- [ ] Copy from a password manager: nothing may be recorded.
- [ ] Fill history past the free limit: oldest clips drop, no modal storm.
- [ ] Quit and relaunch: duplicates must not reappear (stable SHA-256 hashing).
