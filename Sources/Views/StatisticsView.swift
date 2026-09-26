import Charts
import SwiftUI

/// Usage insights, computed from what is actually recorded.
struct StatisticsView: View {
    @Environment(ClipboardStore.self) private var store
    @Environment(SubscriptionManager.self) private var subscriptions

    var body: some View {
        if !subscriptions.checkAccess(for: .statistics) {
            EmptyStateView(
                icon: "chart.bar",
                title: L("Statistics are part of CopyWell Pro"),
                message: L("See what you copy most, which apps you copy from, and how your history grows over time."),
                actionTitle: L("See CopyWell Pro"),
                action: { subscriptions.showingPaywall = true }
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metric.sectionSpacing) {
                    summaryRow
                    typeBreakdown
                    topApps
                }
                .padding(Theme.Metric.gutter + 4)
            }
        }
    }

    private var tracker: StatisticsTracker { .shared }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            StatTile(label: L("Clips stored"), value: "\(store.items.count)")
            StatTile(label: L("Copied all time"), value: "\(tracker.totalCopied)")
            StatTile(label: L("Pasted all time"), value: "\(tracker.totalPasted)")
            StatTile(label: L("Copied today"), value: "\(tracker.dailyCopies)")
        }
    }

    private var typeBreakdown: some View {
        let counts = Dictionary(grouping: store.items, by: \.type)
            .map { (type: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }

        return VStack(alignment: .leading, spacing: 8) {
            Text(L("By type"))
                .font(.headline)
            if counts.isEmpty {
                Text(L("Nothing recorded yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Chart(counts, id: \.type) { entry in
                    BarMark(
                        x: .value(L("Clips"), entry.count),
                        y: .value(L("Type"), entry.type.displayName)
                    )
                    .foregroundStyle(Theme.accent)
                    .cornerRadius(3)
                }
                .chartXAxis { AxisMarks(position: .bottom) }
                .frame(height: CGFloat(counts.count) * 26 + 30)
            }
        }
    }

    private var topApps: some View {
        let apps = tracker.getTopApps(limit: 8)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("Most copied from"))
                .font(.headline)
            if apps.isEmpty {
                Text(L("No source apps recorded yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps, id: \.app) { entry in
                    HStack {
                        Text(entry.app)
                        Spacer()
                        Text(L("\(entry.count)"))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.separator, lineWidth: 0.5))
    }
}
