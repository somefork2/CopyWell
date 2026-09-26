import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSection

    @Environment(ClipboardStore.self) private var store
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(\.openSettings) private var openSettings

    @State private var editingBoard: Pinboard?
    @State private var isCreatingBoard = false

    var body: some View {
        List(selection: $selection) {
            Section(L("Library")) {
                Label(L("History"), systemImage: "clock")
                    .badge(store.items.count)
                    .tag(SidebarSection.history)

                Label(L("Favourites"), systemImage: "star")
                    .badge(store.items.count(where: \.isFavorite))
                    .tag(SidebarSection.favorites)

                Label(L("Paste Stack"), systemImage: "square.stack")
                    .badge(PasteStackManager.shared.stackItems.count)
                    .tag(SidebarSection.pasteStack)

                Label(L("Recordings"), systemImage: "film.stack")
                    .badge(RecordingLibrary.shared.recordings.count)
                    .tag(SidebarSection.recordings)
            }

            Section {
                ForEach(store.pinboards) { board in
                    Label {
                        Text(board.name)
                    } icon: {
                        Image(systemName: board.icon)
                            .foregroundStyle(Color.named(board.color))
                    }
                    .badge(board.items.count)
                    .tag(SidebarSection.pinboard(board.id))
                    .contextMenu {
                        Button(L("Edit…")) { editingBoard = board }
                        Button(L("Delete Pinboard"), role: .destructive) {
                            store.deletePinboard(board)
                        }
                    }
                }
                .onMove { store.movePinboards(from: $0, to: $1) }
            } header: {
                HStack {
                    Text(L("Pinboards"))
                    Spacer()
                    Button {
                        startCreatingPinboard()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.hoverIcon)
                    .help(L("New pinboard"))
                }
            }

            Section(L("Insights")) {
                Label(L("Statistics"), systemImage: "chart.bar")
                    .tag(SidebarSection.statistics)
            }
        }
        .listStyle(.sidebar)
        .themedScrollBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) { settingsRow }
        .safeAreaInset(edge: .bottom) { statusFooter }
        .sheet(isPresented: $isCreatingBoard) {
            PinboardEditor(board: nil) { isCreatingBoard = false }
        }
        .sheet(item: $editingBoard) { board in
            PinboardEditor(board: board) { editingBoard = nil }
        }
    }

    private func startCreatingPinboard() {
        let limit = subscriptions.pinboardLimit
        if limit >= 0 && store.pinboards.count >= limit {
            subscriptions.requestAccess(for: .unlimitedPinboards)
            return
        }
        isCreatingBoard = true
    }

    /// Settings sits at the foot of the sidebar, where a utility's preferences
    /// are easiest to find — not everyone reaches for ⌘, or the app menu.
    private var settingsRow: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    openSettings()
                } label: {
                    Label(L("Settings"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlate(padding: 5))
                .help(L("Settings (⌘,)"))

                Button {
                    AppCoordinator.shared.showSetupGuide()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverIcon)
                .help(L("Setup guide"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Where the user stands, stated plainly and without a modal.
    ///
    /// During the trial it counts down; afterwards it says the app is locked and
    /// that nothing was deleted. Nothing is shown to a subscriber.
    @ViewBuilder
    private var statusFooter: some View {
        if !subscriptions.isPro {
            VStack(alignment: .leading, spacing: 5) {
                Divider()

                if subscriptions.isInFreeTrial {
                    let trial = TrialManager.shared
                    HStack {
                        Text(L("Trial"))
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(L("\(trial.daysRemaining) days left"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(
                        value: max(0, TrialManager.duration - trial.endDate.timeIntervalSinceNow),
                        total: TrialManager.duration
                    )
                    .progressViewStyle(.linear)
                    Text(L("Everything is unlocked. A subscription keeps it that way afterwards."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L("Locked"))
                        .font(.caption.weight(.medium))
                    Text(L("CopyWell is locked. Nothing has been deleted."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(L("See CopyWell Pro")) { subscriptions.showingPaywall = true }
                    .buttonStyle(.hoverLink)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }
}
