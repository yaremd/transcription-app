import SwiftUI

/// A cross-meeting inbox of action items, grouped by meeting. Open items only by
/// default; a toggle reveals completed ones. Checking an item saves it back to
/// its meeting; clicking a card's header opens that meeting.
struct TasksView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var entitlements: EntitlementService
    /// Navigates the window to the given meeting (wired by RootView).
    var openMeeting: (UUID) -> Void = { _ in }
    @State private var showCompleted = false

    var body: some View {
        if entitlements.allows(.actionTracking) {
            inbox
        } else {
            // This pane IS the feature — a full explanation beats a dead list.
            ProLockedPane(feature: .actionTracking)
                .navigationTitle("Action Items")
        }
    }

    private var inbox: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Action Items").font(Theme.title)
                    Spacer()
                    Toggle("Show completed", isOn: $showCompleted)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(Theme.sub)
                        .foregroundStyle(.secondary)
                }

                if meetingsWithItems.isEmpty {
                    ContentUnavailableView(
                        "No action items",
                        systemImage: "checklist",
                        description: Text("Open a meeting and tap “Find action items” to collect tasks here."))
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    // One card per meeting, so each source's tasks are clearly
                    // their own group (and never blur together when several
                    // meetings are still unnamed).
                    ForEach(meetingsWithItems) { meeting in
                        VStack(alignment: .leading, spacing: 10) {
                            MeetingCardHeader(meeting: meeting) {
                                openMeeting(meeting.id)
                            }
                            ThemeDivider()
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(itemsToShow(for: meeting)) { item in
                                    Toggle(isOn: binding(meeting, item)) {
                                        Text(item.text)
                                            .font(Theme.body)
                                            .strikethrough(item.done)
                                            .foregroundStyle(item.done ? .secondary : .primary)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surfacePanel()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Action Items")
    }

    private var meetingsWithItems: [Meeting] {
        store.meetings.filter { !itemsToShow(for: $0).isEmpty }
    }

    private func itemsToShow(for meeting: Meeting) -> [ActionItem] {
        let items = meeting.actionItems ?? []
        return showCompleted ? items : items.filter { !$0.done }
    }

    private func binding(_ meeting: Meeting, _ item: ActionItem) -> Binding<Bool> {
        Binding(
            get: { item.done },
            set: { newValue in
                var updated = meeting
                var items = updated.actionItems ?? []
                guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
                items[idx].done = newValue
                updated.actionItems = items
                store.save(updated)
            }
        )
    }
}

/// A card's header row — the whole row is a click target that opens the
/// meeting; the chevron and hover tint say so.
private struct MeetingCardHeader: View {
    let meeting: Meeting
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meeting.displayTitle)
                    .font(Theme.bodyMedium)
                    .foregroundStyle(hovering ? Theme.accent : .primary)
                    .lineLimit(1)
                let open = meeting.openActionItems.count
                if open > 0 {
                    Text("\(open)")
                        .font(Theme.meta)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(meeting.date, style: .date)
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open this meeting")
    }
}
