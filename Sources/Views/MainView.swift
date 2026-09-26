import SwiftUI

/// Sections of the sidebar.
enum SidebarSection: Hashable, Identifiable {
    case history
    case favorites
    case pasteStack
    case statistics
    case recordings
    case pinboard(UUID)

    var id: String {
        switch self {
        case .history: return "history"
        case .favorites: return "favorites"
        case .pasteStack: return "pasteStack"
        case .statistics: return "statistics"
        case .recordings: return "recordings"
        case .pinboard(let id): return id.uuidString
        }
    }
}

struct MainView: View {
    @Environment(ClipboardStore.self) private var store
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(AppCoordinator.self) private var coordinator

    @State private var section: SidebarSection = .history
    @State private var showSidebar = true
    @State private var searchText = ""
    @State private var typeFilter: ContentType?
    @State private var showingClearConfirmation = false
    @State private var showingWelcome = false

    var body: some View {
        @Bindable var subscriptions = subscriptions

        // Not a NavigationSplitView.
        //
        // Hiding the sidebar killed the app on every attempt, builds 12 to 18,
        // always inside AppKit or SwiftUI and never in a frame of ours. Two
        // distinct stacks came out of it: the split view's column wrapper
        // changing the hosting view's safe-area insets during the window's
        // constraints pass, and SwiftUI's own toolbar bridge rebuilding its
        // items. The collapse and the button that drives it are both framework
        // machinery, so there was nothing left in it to fix.
        //
        // A plain HStack and our own toggle remove that machinery entirely.
        // What is given up is the system's drag-to-resize divider, which is a
        // small price for a sidebar that can be closed and opened again.
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(selection: $section)
                    .frame(width: 210)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            detail
        }
        .background(Theme.background)
        .themedWindow()
        .frame(minWidth: 860, minHeight: 520)
        .toolbar { toolbar }
        .searchable(text: $searchText, placement: .toolbar, prompt: L("Search clips"))
        .sheet(isPresented: $showingWelcome) {
            SetupWizard { showingWelcome = false }
        }
        .onAppear {
            showingWelcome = !AppSettings.shared.hasCompletedOnboarding
        }
        .sheet(isPresented: $subscriptions.showingPaywall) {
            PaywallView()
                .environment(subscriptions)
        }
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
            Text(L("This permanently removes the clips and any images stored with them. It cannot be undone."))
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyWellRequestClearHistory)) { _ in
            showingClearConfirmation = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyWellRequestSetupWizard)) { _ in
            showingWelcome = true
        }
        .overlay(alignment: .top) { conflictBanner }
        .overlay(alignment: .bottom) { skipNotice }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .statistics:
            StatisticsView()
        case .pasteStack:
            PasteStackView()
        case .recordings:
            RecordingsView(searchText: searchText)
        default:
            ClipboardListView(
                items: filteredItems,
                searchText: searchText,
                typeFilter: $typeFilter
            )
        }
    }

    private var filteredItems: [ClipboardItem] {
        var result = store.items

        switch section {
        case .favorites: result = result.filter(\.isFavorite)
        case .pinboard(let id): result = result.filter { $0.pinboard?.id == id }
        default: break
        }

        if let typeFilter {
            result = result.filter { $0.type == typeFilter }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.searchCorpus.contains(query) }
        }

        return result
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Every item in one trailing group, on the right.
        //
        // The sidebar toggle was briefly moved to `.navigation` so the toolbar
        // could never sweep it into the » overflow. That placement puts it
        // beside the window controls — which on this window means on top of the
        // sidebar itself, dragging the neighbouring icons and the window title
        // over with it. Measured afterwards: at 860pt, the narrowest this
        // window goes, nothing overflows anyway, so there was nothing to buy
        // with that trade.
        ToolbarItemGroup {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSidebar.toggle() }
            } label: {
                Label(L("Sidebar"), systemImage: "sidebar.left")
            }
            .help(showSidebar ? L("Hide the sidebar") : L("Show the sidebar"))

            Button {
                QuickPastePanel.shared.toggle()
            } label: {
                Label(L("Palette"), systemImage: "rectangle.and.text.magnifyingglass")
            }
            .help(L("Open the clipboard palette (⌥⌘V)"))

            Button {
                coordinator.togglePause()
            } label: {
                Label(
                    coordinator.isPaused ? L("Resume") : L("Pause"),
                    systemImage: coordinator.isPaused ? "play" : "pause"
                )
            }
            .help(coordinator.isPaused ? L("Resume recording") : L("Pause recording"))

            if !subscriptions.isPro {
                Button(L("Upgrade")) { subscriptions.showingPaywall = true }
            }
        }
    }

    /// A clip that was refused on purpose is announced, because a copy that
    /// simply never appears looks like a bug.
    @ViewBuilder
    private var skipNotice: some View {
        if PrivacyLog.shared.hasRecentSkip {
            Label(L("A clip that looked like a password was not recorded."), systemImage: "lock")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var conflictBanner: some View {
        if let message = coordinator.shortcutConflictMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
