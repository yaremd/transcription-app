import SwiftUI

/// A cross-meeting inbox of action items, grouped by meeting. Open items only by
/// default; a toggle reveals completed ones. Checking an item saves it back to
/// its meeting.
struct TasksView: View {
    @EnvironmentObject private var store: MeetingStore
    @State private var showCompleted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Action Items").font(.title2).bold()
                    Spacer()
                    Toggle("Show completed", isOn: $showCompleted)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if meetingsWithItems.isEmpty {
                    ContentUnavailableView(
                        "No action items",
                        systemImage: "checklist",
                        description: Text("Open a meeting and tap “Find action items” to collect tasks here."))
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ForEach(meetingsWithItems) { meeting in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(meeting.title).font(.headline)
                            Text(meeting.date, style: .date)
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(itemsToShow(for: meeting)) { item in
                                Toggle(isOn: binding(meeting, item)) {
                                    Text(item.text)
                                        .strikethrough(item.done)
                                        .foregroundStyle(item.done ? .secondary : .primary)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.bottom, 4)
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
