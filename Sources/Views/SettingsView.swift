import AppKit
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            PrivacySettings()
                .tabItem { Label(L("Privacy"), systemImage: "hand.raised") }
            ShortcutSettings()
                .tabItem { Label(L("Shortcuts"), systemImage: "command") }
            AppearanceSettings()
                .tabItem { Label(L("Appearance"), systemImage: "paintbrush") }
            SyncSettings()
                .tabItem { Label(L("Sync & Export"), systemImage: "icloud") }
            SubscriptionSettings()
                .tabItem { Label(L("Subscription"), systemImage: "creditcard") }
        }
        // Six tabs, and the labels are long in several of the languages we
        // ship: at 560 the last two fell into the ">>" overflow menu and could
        // not be reached at all. Sized for the longest of them.
        .frame(width: 780)
        .themedWindow()
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SubscriptionManager.self) private var subscriptions

    /// What is actually in force: a locked app cleans nothing up, so the chosen
    /// policy is replaced by an explanation of the lock.
    private var effectiveRetentionText: String {
        guard subscriptions.checkAccess(for: .autoCleanup) else {
            return L("CopyWell is locked without a subscription: it stops recording, and the window asks you to subscribe. Nothing is deleted.")
        }
        return settings.retention.explanation
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle(L("Launch CopyWell at login"), isOn: $settings.launchAtLogin)
                Toggle(L("Show icon in the Dock"), isOn: $settings.showInDock)
                Toggle(L("Show icon in the menu bar"), isOn: $settings.showInMenuBar)
            } footer: {
                Text(L("With the Dock icon hidden, the menu bar item stays available so CopyWell is always reachable."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("Play sounds"), isOn: $settings.soundsEnabled)
                Picker(L("When a clip is captured"), selection: $settings.captureSound) {
                    ForEach(FeedbackSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }
                .disabled(!settings.soundsEnabled)
                .onChange(of: settings.captureSound) { _, new in new.play() }

                Picker(L("When a clip is used"), selection: $settings.pasteSound) {
                    ForEach(FeedbackSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }
                .disabled(!settings.soundsEnabled)
                .onChange(of: settings.pasteSound) { _, new in new.play() }
            } header: {
                Text(L("Sound"))
            } footer: {
                Text(L("Off after installation. Changing a sound plays it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("Record the Mac's sound"), isOn: $settings.recordSystemAudio)
                Toggle(L("Show the pointer in recordings"), isOn: $settings.recordShowsPointer)
                Toggle(L("Show clicks in recordings"), isOn: $settings.recordShowsClicks)
                Toggle(L("Count down before recording"), isOn: $settings.recordCountdown)
                Toggle(L("Open the recording when it is finished"), isOn: $settings.openRecordingWhenDone)
                LabeledContent(L("Screen Recording permission")) {
                    if ScreenCaptureAccess.isGranted {
                        Label(L("Allowed"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(L("Open System Settings")) {
                            NSWorkspace.shared.open(ScreenCaptureAccess.settingsURL)
                        }
                    }
                }
            } header: {
                Text(L("Screenshots & Recording"))
            } footer: {
                Text(L("Screenshots are copied and added to your history; ⌘S in the overlay saves them to a file instead. Recordings are saved to Movies ▸ CopyWell and copied as a file. Both need the Screen Recording permission, which is asked for the first time you use them."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RecordingPresenterSettings()

            // macOS ships both of these switched off, and neither can be
            // turned on from inside an app — only pointed at. Without this
            // section people cannot find them: the entries are called Services
            // and Finder Extensions in System Settings, not "right-click menu",
            // which is what they are looking for.
            Section {
                Button(L("Finder Extensions…")) {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
                Button(L("Keyboard Shortcuts ▸ Services…")) {
                    NSUpdateDynamicServices()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(L("Show the setup guide again")) {
                    AppCoordinator.shared.showSetupGuide()
                }
            } header: {
                Text(L("Right-click menu"))
            } footer: {
                Text(L("CopyWell's right-click entries are macOS Services, which macOS keeps switched off until someone chooses otherwise. In that list the groups start collapsed; the CopyWell entries live under Text, Images, and Files and Folders. The Finder menu is a separate switch, under Finder Extensions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LanguagePicker()
                Picker(L("Text size"), selection: $settings.textSize) {
                    ForEach(TextSizePreference.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
            } header: {
                Text(L("Accessibility"))
            } footer: {
                Text(L("The language changes as soon as it is picked. Text size scales every label, and the rows grow with it; it is independent of the system-wide setting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(L("Keep"), selection: $settings.retention) {
                    Section(L("By number of clips")) {
                        ForEach(RetentionPolicy.presets.filter { if case .count = $0 { return true }; return false }) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    Section(L("By age")) {
                        ForEach(RetentionPolicy.presets.filter { if case .days = $0 { return true }; return false }) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    Text(RetentionPolicy.forever.displayName).tag(RetentionPolicy.forever)
                }
                .disabled(!subscriptions.checkAccess(for: .autoCleanup))

                Text(effectiveRetentionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(L("Favourites and clips on a pinboard are never removed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !subscriptions.hasFullAccess {
                    LabeledContent(L("Status")) {
                        HStack {
                            Text(L("Locked"))
                                .foregroundStyle(.secondary)
                            Button(L("See CopyWell Pro")) { subscriptions.showingPaywall = true }
                                .buttonStyle(.hoverLink)
                        }
                    }
                }
            } header: {
                Text(L("History"))
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClipboardStore.self) private var store
    @State private var showingClearConfirmation = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle(L("Ignore items marked secret by other apps"), isOn: $settings.skipConcealedPasteboard)
                Toggle(L("Never record anything that looks like a password"), isOn: $settings.skipPasswords)
                Toggle(L("Hide CopyWell windows from screen recordings"), isOn: $settings.hideFromScreenCapture)
            } footer: {
                Text(L("""
                Password managers mark their copies with the standard \
                org.nspasteboard.ConcealedType flag; CopyWell skips those and never \
                records copies made in known password managers. Items you mark as \
                sensitive yourself are encrypted with a key kept in your login keychain.
                """))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(L("Stored data")) {
                LabeledContent(L("Clips on this Mac"), value: "\(store.items.count)")
                LabeledContent(L("Encrypted clips"), value: "\(store.items.count(where: \.isSensitive))")
                LabeledContent(L("Skipped as sensitive"), value: "\(PrivacyLog.shared.skippedTotal)")
                Button(L("Clear History…"), role: .destructive) {
                    showingClearConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
        .confirmationDialog(
            L("Clear clipboard history?"),
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("Delete All Except Favourites"), role: .destructive) {
                store.clearHistory(keepingFavorites: true)
            }
            Button(L("Delete Everything"), role: .destructive) {
                store.clearHistory(keepingFavorites: false)
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Clips and their stored images are removed permanently."))
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @Environment(SubscriptionManager.self) private var subscriptions
    private var manager: GlobalShortcutsManager { .shared }

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action)
                            .disabled(!subscriptions.hasFullAccess)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.title)
                            Text(action.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Inside the palette: ↑↓ to move, ⌘1–9 to jump, ⏎ to copy the clip and return to your app, ⌥⏎ without formatting, ⌘Y to preview, ⌘⌫ to delete, ⎋ to close. Press ⌘V to paste."))
                    Text(L("CopyWell never presses keys for you, so it needs no Accessibility access. To insert a clip without pressing ⌘V, use Services ▸ Paste from CopyWell."))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Button(L("Reset All Shortcuts")) { manager.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @State private var theme = ThemeManager.shared

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        @Bindable var theme = theme

        Form {
            Section(L("Theme")) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(AppTheme.allCases) { option in
                        ThemeSwatch(theme: option, isSelected: theme.currentTheme == option) {
                            theme.currentTheme = option
                        }
                    }
                }
                .padding(.vertical, 4)

                Text(theme.currentTheme.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Accent colour")) {
                HStack(spacing: 8) {
                    // "Theme" means each theme keeps the accent it was designed
                    // around; picking a colour overrides that everywhere.
                    Button {
                        theme.accentColorName = nil
                    } label: {
                        Circle()
                            .fill(theme.currentTheme.palette.accent)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .stroke(.primary, lineWidth: theme.accentColorName == nil ? 2 : 0)
                                    .padding(-3)
                            )
                    }
                    .buttonStyle(.hoverLift(scale: 1.15))
                    .help(L("Use the colour this theme was designed around"))
                    .accessibilityLabel(L("Theme accent"))

                    Divider().frame(height: 18)

                    ForEach(ThemeManager.accentOptions, id: \.self) { name in
                        Button {
                            theme.accentColorName = name
                        } label: {
                            Circle()
                                .fill(Color.named(name))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle()
                                        .stroke(.primary, lineWidth: theme.accentColorName == name ? 2 : 0)
                                        .padding(-3)
                                )
                        }
                        .buttonStyle(.hoverLift(scale: 1.15))
                        .accessibilityLabel(name)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
    }
}

/// A miniature of the app drawn in the theme's own colours, so the choice is
/// made by looking rather than by reading colour names.
struct ThemeSwatch: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                preview
                HStack(spacing: 4) {
                    Text(theme.displayName)
                        .font(.callout)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    // Theme.accent, not Color.accentColor: the latter is the
                    // system accent from macOS settings and ignores `.tint`, so
                    // the ring round the chosen theme came out system blue next
                    // to a swatch painted in the theme's own colour.
                    .stroke(isSelected ? Theme.accent : Theme.separator,
                            lineWidth: isSelected ? 2 : 0.5)
            )
        }
        .buttonStyle(.hoverLift(scale: 1.03))
        .accessibilityLabel(L("\(theme.displayName) theme"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var preview: some View {
        let palette = theme.palette
        HStack(spacing: 0) {
            // Sidebar
            Rectangle()
                .fill(palette.surface)
                .frame(width: 26)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule()
                                .fill(index == 0 ? palette.accent : palette.separator)
                                .frame(width: index == 0 ? 16 : 13, height: 3)
                        }
                    }
                    .padding(5)
                }

            Rectangle()
                .fill(palette.separator)
                .frame(width: 0.5)

            // Content rows
            Rectangle()
                .fill(palette.background)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<4, id: \.self) { index in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(palette.surface)
                                    .frame(width: 8, height: 8)
                                Capsule()
                                    .fill(palette.separator)
                                    .frame(width: index == 1 ? 34 : 46, height: 3)
                            }
                        }
                    }
                    .padding(6)
                }
        }
        .frame(height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(palette.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - Sync & Export

struct SyncSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ClipboardStore.self) private var store
    @Environment(SubscriptionManager.self) private var subscriptions

    @State private var sync = SyncCoordinator.shared
    @State private var accountStatus: String?
    @State private var exportFormat: ExportFormat = .json

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section(L("iCloud")) {
                Toggle(L("Sync history across my Macs"), isOn: $settings.iCloudSync)
                    .disabled(!subscriptions.hasFullAccess)
                    .onChange(of: settings.iCloudSync) { _, enabled in
                        sync.settingsChanged()
                        if enabled { Task { await checkAccount() } }
                    }

                if let message = sync.status.message ?? accountStatus {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await sync.syncNow(userInitiated: true) }
                } label: {
                    if sync.status == .syncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L("Sync Now"))
                    }
                }
                .disabled(!settings.iCloudSync || sync.status == .syncing || !subscriptions.hasFullAccess)

                Text(L("CopyWell syncs on launch, when you switch back to it, and a few seconds after you copy something. Images and items marked sensitive stay on this Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Export")) {
                Picker(L("Format"), selection: $exportFormat) {
                    Text(L("JSON")).tag(ExportFormat.json)
                    Text(L("CSV")).tag(ExportFormat.csv)
                    Text(L("Markdown")).tag(ExportFormat.markdown)
                    Text(L("HTML")).tag(ExportFormat.html)
                }
                Button(L("Export History…")) { export() }
                    .disabled(store.items.isEmpty)
                Text(L("Sensitive clips are never included in exports."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
    }

    private func checkAccount() async {
        let available = await CloudKitSyncManager.shared.checkAccountStatus()
        accountStatus = available
            ? L("Connected to your private iCloud database.")
            : L("Sign in to iCloud in System Settings to use sync.")
    }

    /// Writes through an NSSavePanel, which is also how a sandboxed app gets
    /// permission to write where the user chose.
    ///
    /// Deliberately not gated. The subscription wall promises that nothing the
    /// user saved is deleted; holding their own history hostage behind a lapsed
    /// subscription would make that promise worthless, and someone who cannot
    /// get their data out asks for a refund rather than resubscribing.
    private func export() {
        guard let data = ExportManager.export(items: store.items, format: exportFormat) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CopyWell Export.\(exportFormat.fileExtension)"
        panel.allowedContentTypes = [exportFormat.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

// MARK: - Subscription

struct SubscriptionSettings: View {
    @Environment(SubscriptionManager.self) private var manager

    var body: some View {
        Form {
            Section(L("Plan")) {
                LabeledContent(L("Status"), value: statusText)
                if let expiry = manager.expirationDate {
                    LabeledContent(
                        manager.isInTrial ? L("Trial ends") : L("Renews"),
                        value: expiry.formatted(
                            Date.FormatStyle(date: .abbreviated, time: .shortened,
                                             locale: LanguageBundle.locale))
                    )
                }
                if !manager.isPro {
                    Button(L("See CopyWell Pro")) { manager.showingPaywall = true }
                }
                Button(L("Restore Purchases")) {
                    Task { await manager.restorePurchases() }
                }
                Button(L("Manage Subscription")) { manager.showManageSubscriptions() }
                if let error = manager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            #if DEBUG
            Section {
                @Bindable var manager = manager
                Toggle("Simulate Pro", isOn: $manager.simulatedPro)
                Text("Development builds only — this section does not exist in a release build. It unlocks every paid feature so the full experience can be reviewed before the products are live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Developer")
            }
            #endif

            Section(L("Legal")) {
                Link(L("Privacy Policy"), destination: LegalLinks.privacyPolicy)
                Link(L("Terms of Use"), destination: LegalLinks.termsOfUse)
                Link(L("Support"), destination: LegalLinks.support)
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
        .task { await manager.refreshEntitlement() }
    }

    private var statusText: String { manager.statusDescription }
}

// MARK: - Camera and microphone

/// The presenter's camera and voice. Each switch asks for its permission the
/// moment it is turned on, and not before; turned down, the switch goes back
/// off and says where the setting lives.
struct RecordingPresenterSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Section {
            Toggle(L("Show my camera in a bubble"), isOn: $settings.recordCamera)
                .onChange(of: settings.recordCamera) { _, on in
                    guard on else { return }
                    Task { if !(await MediaAccess.request(.camera)) { settings.recordCamera = false } }
                }
            if settings.recordCamera {
                Picker(L("Camera"), selection: $settings.cameraID) {
                    Text(L("Default")).tag(String?.none)
                    ForEach(MediaAccess.cameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                Picker(L("Bubble size"), selection: $settings.cameraSize) {
                    ForEach(CameraBubbleSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
            }

            Toggle(L("Record my voice"), isOn: $settings.recordMicrophone)
                .onChange(of: settings.recordMicrophone) { _, on in
                    guard on else { return }
                    Task { if !(await MediaAccess.request(.microphone)) { settings.recordMicrophone = false } }
                }
            if settings.recordMicrophone {
                Picker(L("Microphone"), selection: $settings.microphoneID) {
                    Text(L("Default")).tag(String?.none)
                    ForEach(MediaAccess.microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
            }
        } header: {
            Text(L("Camera & Microphone"))
        } footer: {
            Text(L("Both are off until you switch them on, and CopyWell asks for the camera or the microphone only then. The bubble can be dragged anywhere during a recording; double-click it to change its size."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
