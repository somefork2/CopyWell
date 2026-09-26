import SwiftUI

/// The Recordings section: every screen recording in Movies ▸ CopyWell, newest
/// first, as cards with the first frame, the length and the date. Double-click
/// one to watch it, trim it or send it on.
struct RecordingsView: View {
    let searchText: String

    @State private var library = RecordingLibrary.shared
    @State private var selection: URL?

    private var recordings: [RecordingLibrary.Recording] {
        guard !searchText.isEmpty else { return library.recordings }
        return library.recordings.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if recordings.isEmpty {
                EmptyStateView(
                    icon: "record.circle",
                    title: searchText.isEmpty ? L("No recordings yet") : L("No matches"),
                    message: searchText.isEmpty
                        ? L("Press ⇧⌘0 to record the screen, with your camera and voice if you like. Recordings are saved to Movies ▸ CopyWell and appear here.")
                        : L("Nothing matches “\(searchText)”."),
                    actionTitle: searchText.isEmpty ? L("Record Screen…") : nil,
                    action: searchText.isEmpty ? {
                        AppCoordinator.unlocked { ScreenRecorder.shared.begin() }
                    } : nil
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 16)], spacing: 18) {
                        ForEach(recordings) { recording in
                            RecordingCard(
                                recording: recording,
                                thumbnail: library.thumbnails[recording.url],
                                isSelected: selection == recording.url
                            )
                            .onTapGesture(count: 2) { RecordingReview.show(recording.url) }
                            .simultaneousGesture(TapGesture().onEnded { selection = recording.url })
                            .contextMenu { menu(for: recording) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear { library.refresh() }
    }

    @ViewBuilder
    private func menu(for recording: RecordingLibrary.Recording) -> some View {
        Button(L("Open")) { RecordingReview.show(recording.url) }
        Button(L("Copy")) { RecordingLibrary.copy(recording.url) }
        Button(L("Show in Finder")) { RecordingLibrary.reveal(recording.url) }
        Divider()
        Button(L("Move to Trash"), role: .destructive) { library.moveToTrash(recording.url) }
    }
}

struct RecordingCard: View {
    let recording: RecordingLibrary.Recording
    let thumbnail: NSImage?
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(Image(systemName: "film").font(.title).foregroundStyle(.tertiary))
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipped()
                .overlay {
                    if isHovered {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 38))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                }

                Text(RecordingClock.string(recording.duration))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(recording.created.relativeFormatted)
                    Text(verbatim: "·")
                    Text(ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(isHovered ? 1.015 : 1)
        .shadow(color: .black.opacity(isHovered ? 0.14 : 0), radius: isHovered ? 8 : 0, y: isHovered ? 3 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        .onHover { isHovered = $0 }
        .help(L("Double-click to watch, trim or share"))
    }
}
