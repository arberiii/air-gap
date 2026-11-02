import Charts
import SwiftUI
import AirGapCore

struct ScreenTimeView: View {
    @EnvironmentObject var state: AppState
    @State private var days = 1
    @AppStorage("usageSort") private var sort: UsageSort = .time
    /// The legend entry clicked to filter the list, if any.
    @State private var selectedCategory: String?

    var body: some View {
        let entries = state.usageRows(lastDays: days, sortedBy: sort)
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $days) {
                Text("Today").tag(1); Text("7 days").tag(7)
            }.pickerStyle(.segmented).labelsHidden()
            HStack(alignment: .firstTextBaseline) {
                Text(Formatting.duration(entries.reduce(0) { $0 + $1.seconds })).font(.system(size: 30, weight: .bold))
                Spacer()
                Text("\(entries.reduce(0) { $0 + $1.visits }) opens").foregroundStyle(.secondary)
            }
            if state.coachEnabled {
                CoachButton(title: "Summarize with \(state.agent.name)", disabled: entries.isEmpty) { state.requestUsageSummary(days: days) }
            }
            if let result = state.usageSummary, result.days == days {
                UsageSummaryCard(summary: result.summary) { state.usageSummary = nil }
            } else {
                usageList(entries)
            }
        }
        .task { state.labelCategoriesIfNeeded() }
        .onChange(of: days) { state.labelCategoriesIfNeeded() }
    }

    @ViewBuilder private func usageList(_ all: [UsageEntry]) -> some View {
        let categories = state.categorization
        let items = UsageChart.legend(all, categories: categories)
        // A category with no time in this range shows nothing, so its filter is ignored.
        let active = selectedCategory.flatMap { id in items.contains { $0.category.id == id } ? id : nil }
        let entries = active.map { id in all.filter { categories.categoryID(of: $0.key) == id } } ?? all
        chart(categories, selected: active)
        legend(items, selected: active)
        Picker("Sort by", selection: $sort) {
            Text("Time").tag(UsageSort.time); Text("Opens").tag(UsageSort.opens)
        }.pickerStyle(.segmented).font(.caption)
        List(entries.prefix(30)) { entry in
            HStack {
                ActivityIcon(key: entry.key)
                Text(entry.title).lineLimit(1)
                if entry.isGroup {
                    Text(entry.members.map { $0.isWeb ? $0.identifier : "app" }.joined(separator: " + "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(entry.members.map { "\($0.title): \(Formatting.duration($0.seconds)), \($0.visits)×" }.joined(separator: "\n"))
                }
                Spacer()
                Text("\(entry.visits)×").foregroundStyle(.secondary).help("Times opened")
                Text(Formatting.duration(entry.seconds)).foregroundStyle(.secondary)
                Menu {
                    ItemActions(entry: entry, others: all, block: block)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
            }
            .contextMenu { ItemActions(entry: entry, others: all, block: block) }
        }
        .listStyle(.plain)
        if !state.ignored.isEmpty {
            DisclosureGroup("Not tracked: \(state.ignored.count)") {
                ForEach(state.ignored) { item in
                    HStack {
                        ActivityIcon(key: item.key)
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Button("Track again") { state.trackAgain(item) }.controlSize(.small)
                    }
                }
            }
            .font(.callout)
        }
    }

    /// Today by hour (minutes) or the week by day (hours), stacked by category like macOS Screen Time.
    private func chart(_ categories: Categorization, selected: String?) -> some View {
        let hourly = days == 1
        let start = Calendar.current.startOfDay(for: Date())
        let slices = state.categoryChart(lastDays: days)
        return Chart {
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                BarMark(x: .value("Time", slice.bucket, unit: hourly ? .hour : .day),
                        y: .value(hourly ? "Minutes" : "Hours", hourly ? slice.seconds / 60 : slice.seconds / 3600))
                    .foregroundStyle(by: .value("Category", slice.categoryID))
                    .opacity(selected == nil || selected == slice.categoryID ? 1 : 0.25)
            }
        }
        .chartForegroundStyleScale(domain: categories.categories.map(\.id), range: categories.categories.map(CategoryPalette.color))
        .chartLegend(.hidden)
        .chartXScale(domain: hourly ? start...(Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
                     : (Calendar.current.date(byAdding: .day, value: -(days - 1), to: start) ?? start)...(Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start))
        .chartXAxis {
            if hourly {
                AxisMarks(values: .stride(by: .hour, count: 6)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
            } else {
                AxisMarks(values: .stride(by: .day)) { AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.narrow)) }
            }
        }
        .frame(height: 100)
    }

    /// Each category's total. Clicking one filters the list to it; clicking it again clears the filter.
    private func legend(_ items: [(category: UsageCategory, seconds: TimeInterval)], selected: String?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.category.id) { item in
                Button {
                    selectedCategory = selected == item.category.id ? nil : item.category.id
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(CategoryPalette.color(item.category)).frame(width: 8, height: 8)
                        Text(item.category.name).lineLimit(1)
                        Text(Formatting.duration(item.seconds)).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(selected == nil || selected == item.category.id ? 1 : 0.4)
                .help(selected == item.category.id ? "Show all" : "Show only \(item.category.name)")
            }
        }
    }

    private func block(_ entry: UsageEntry) {
        for part in entry.parts {
            if part.isWeb { state.addWebRule(part.identifier, kind: .site, limit: nil) }
            else { state.addAppRule(bundleID: part.identifier, name: part.title, limit: nil) }
        }
    }
}

/// The assistant's summary of the screen time shown, in place of the list until closed.
private struct UsageSummaryCard: View {
    let summary: CoachUsageSummary
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(summary.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Back to the list")
                }
                Label(summary.trend.label, systemImage: icon).font(.callout.weight(.semibold)).foregroundStyle(color)
                Text(summary.productivity).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Patterns").font(.subheadline.weight(.semibold))
                ForEach(summary.patterns, id: \.self) { pattern in
                    Label(pattern, systemImage: "circle.fill").labelStyle(BulletLabelStyle()).font(.callout)
                }
                Text(summary.suggestion).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 2)
        }
    }

    private var icon: String {
        switch summary.trend {
        case .better: "arrow.up.right.circle.fill"
        case .same: "equal.circle.fill"
        case .worse: "arrow.down.right.circle.fill"
        case .unclear: "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch summary.trend {
        case .better: .green
        case .same: .secondary
        case .worse: .orange
        case .unclear: .secondary
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Per-row actions for the screen time list, shared by the ⋯ menu and the right-click menu.
private struct ItemActions: View {
    @EnvironmentObject var state: AppState
    let entry: UsageEntry
    /// The other rows on screen, offered under "Group with…".
    let others: [UsageEntry]
    let block: (UsageEntry) -> Void

    var body: some View {
        Button { block(entry) } label: { Label(entry.isGroup ? "Add all to block list" : "Add to block list", systemImage: "nosign") }
        Divider()
        Menu {
            ForEach(others.filter { $0.key != entry.key }.prefix(20)) { other in
                Button(other.title) { state.group(entry, with: other) }
            }
        } label: { Label("Group with…", systemImage: "rectangle.stack.badge.plus") }
        Menu {
            let current = state.categorization.categoryID(of: entry.key)
            ForEach(state.categorization.categories) { category in
                Button { state.setCategory(category.id, for: entry) } label: {
                    if category.id == current { Label(category.name, systemImage: "checkmark") } else { Text(category.name) }
                }
            }
        } label: { Label("Category", systemImage: "tag") }
        if entry.isGroup {
            Button { state.separate(entry) } label: { Label("Separate", systemImage: "rectangle.split.2x1") }
        }
        Divider()
        Button { state.removeFromLog(entry, stopTracking: false) } label: { Label("Remove from log", systemImage: "trash") }
        Button { state.removeFromLog(entry, stopTracking: true) } label: { Label("Remove and stop tracking", systemImage: "eye.slash") }
    }
}
