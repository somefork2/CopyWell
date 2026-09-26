import AppKit
import SwiftUI

/// First-run setup.
///
/// Four screens, each making one point and showing it. The Services step
/// matters most: macOS ships third-party menu items switched off, so without
/// being told, people never find the right-click entries and conclude they are
/// broken.
struct SetupWizard: View {
    let onFinish: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var step = 0
    @State private var goingForward = true
    @State private var theme = ThemeManager.shared

    // Three. The Services step moved into Settings ▸ General: a first-run
    // screen about switching things on in System Settings reads as being told
    // what to do before the app has done anything for you.
    private let stepCount = 4

    var body: some View {
        @Bindable var bindableSettings = settings

        VStack(spacing: 0) {
            header
            Divider()

            ZStack {
                switch step {
                case 0: language
                case 1: welcome
                case 2: essentials
                default: personalise(
                    soundsEnabled: $bindableSettings.soundsEnabled,
                    launchAtLogin: $bindableSettings.launchAtLogin
                )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            // Each step slides in from the direction of travel, so moving back
            // feels like going back rather than like a different screen.
            .transition(.asymmetric(
                insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
            ))
            .id(step)

            Divider()
            footer
        }
        .frame(width: 660, height: 600)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(L("Step \(step + 1) of \(stepCount)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            progressDots
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// The real app icon, so the guide looks like it belongs to the app.
    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: 40, height: 40)
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index == step ? Theme.accent : Color.secondary.opacity(0.28))
                    .frame(width: index == step ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
    }

    private var title: String {
        switch step {
        case 0: return L("Choose a language")
        case 1: return L("Welcome to CopyWell")
        case 2: return L("Two things worth remembering")
        default: return L("Make it yours")
        }
    }

    private var footer: some View {
        HStack {
            Button(L("Skip setup")) { finish() }
                .buttonStyle(.hoverLink)
            Spacer()
            if step > 0 {
                Button(L("Back")) { move(to: step - 1) }
            }
            Button(step == stepCount - 1 ? L("Start using CopyWell") : L("Continue")) {
                step == stepCount - 1 ? finish() : move(to: step + 1)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func move(to newStep: Int) {
        goingForward = newStep > step
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            step = newStep
        }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        onFinish()
    }

    // MARK: - Steps

    /// First, so that everything after it is read in the reader's own language.
    private var language: some View {
        StepLayout(
            headline: L("Which language should CopyWell speak?"),
            illustration: { AnimatedIn { WizardIllustration.Language() } }
        ) {
            LanguagePicker()
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)

            Text(L("CopyWell is translated into \(AppSettings.availableLanguages.count) languages. The rest of this guide, and the app itself, change as soon as one is picked."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        StepLayout(
            headline: L("CopyWell keeps what you copy, so you can get it back later."),
            illustration: { AnimatedIn { WizardIllustration.Privacy() } }
        ) {
            bullet("lock", L("Everything stays on this Mac."),
                   L("Nothing is uploaded unless you turn on iCloud sync yourself."))
            bullet("hand.raised", L("No permissions are requested."),
                   L("CopyWell never presses keys for you, so it needs no Accessibility access."))
            bullet("eye.slash", L("Password managers are respected."),
                   L("Copies marked secret by 1Password, Bitwarden or Keychain are never recorded."))
        }
    }

    private var essentials: some View {
        StepLayout(
            headline: L("Press ⌥⌘V anywhere, pick a clip, press ⌘V."),
            illustration: { AnimatedIn { WizardIllustration.Shortcut() } }
        ) {
            bullet("command", L("The palette opens at your cursor."),
                   L("Move with ↑↓ or jump with ⌘1–9. ⌘Y looks at a clip before you take it."))
            bullet("menubar.arrow.up.rectangle", L("The menu bar icon shows recent clips."),
                   L("Click one to put it back on the clipboard without opening the app."))
            bullet("square.stack", L("Pinboards and the paste stack are there when you need them."),
                   L("Keep clips you reuse, or queue several and paste them in order."))
        }
    }

    private func personalise(
        soundsEnabled: Binding<Bool>,
        launchAtLogin: Binding<Bool>
    ) -> some View {
        StepLayout(
            headline: L("A look, and whether CopyWell makes a sound."),
            illustration: { AnimatedIn { WizardIllustration.Personalise() } }
        ) {
            LabeledContent(L("Theme")) {
                Picker("", selection: Binding(
                    get: { theme.currentTheme },
                    set: { theme.currentTheme = $0 }
                )) {
                    ForEach(AppTheme.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Toggle(L("Play a sound when something is copied"), isOn: soundsEnabled)
            Text(L("Off by default. A utility that beeps every time you copy gets uninstalled."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(L("Start CopyWell at login"), isOn: launchAtLogin)
            Text(L("CopyWell only records while it is running. More themes, accent colours and text size are in Settings."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Illustration on top, one sentence, then the detail — the same shape on every
/// step so moving between them does not feel like moving between apps.
private struct StepLayout<Illustration: View, Content: View>: View {
    let headline: String
    @ViewBuilder let illustration: () -> Illustration
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            illustration()
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.secondaryBackground.opacity(0.55))
                )

            Text(headline)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }

            Spacer(minLength: 0)
        }
    }
}

/// Fades and lifts its content once, when the step appears.
private struct AnimatedIn<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var shown = false

    var body: some View {
        content()
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45).delay(0.08)) { shown = true }
            }
    }
}
