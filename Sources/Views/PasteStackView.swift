import SwiftUI

/// Queue of clips to paste one after another.
struct PasteStackView: View {
    @Environment(SubscriptionManager.self) private var subscriptions
    @State private var stack = PasteStackManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if stack.isEmpty {
                EmptyStateView(
                    icon: "square.stack",
                    title: L("Paste Stack is empty"),
                    message: L("Right-click any clip and choose “Add to Paste Stack”, then paste them in order with ⌥⌘S.")
                )
            } else {
                header
                Divider()
                list
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("\(stack.remaining) of \(stack.stackItems.count) remaining"))
                    .font(.callout)
                ProgressView(value: stack.progress)
                    .frame(width: 180)
            }
            Spacer()
            Button(L("Rewind")) { stack.rewind() }
                .disabled(stack.currentIndex == 0)
            Button(L("Clear"), role: .destructive) { stack.reset() }
        }
        .padding(Theme.Metric.gutter)
    }

    private var list: some View {
        List {
            ForEach(Array(stack.stackItems.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Text(L("\(index + 1)"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(index < stack.currentIndex ? .tertiary : .secondary)
                        .frame(width: 18)
                    TypeBadge(type: item.type)
                    Text(item.previewText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(index < stack.currentIndex ? .secondary : .primary)
                    Spacer()
                    if index < stack.currentIndex {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: Theme.Metric.rowHeight)
                .padding(.horizontal, 8)
                .modifier(RowHover())
                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .onDelete { stack.remove(at: $0) }
            .onMove { stack.move(from: $0, to: $1) }
        }
        .listStyle(.inset)
        .themedScrollBackground()
    }
}
