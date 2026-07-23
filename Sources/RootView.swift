import SwiftUI

/// Which pane the detail area is showing.
enum Panel: Hashable {
    case record
    case tasks
    case meeting(UUID)
}

/// Top-level layout: a searchable sidebar listing past meetings plus a "New
/// Recording" entry, and a detail area showing either the live recorder or a
/// saved meeting. The AudioMonitor lives here (above the detail switch) so
/// switching to a past meeting never interrupts an in-progress recording.
struct RootView: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: AppSettings
    @State private var selection: Panel? = .record
    @State private var searchText = ""
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label {
                        HStack {
                            Text("New Recording").font(Theme.body)
                            if monitor.isRunning {
                                Spacer()
                                Circle()
                                    .fill(Theme.red)
                                    .frame(width: 7, height: 7)
                                    .shadow(color: Theme.red.opacity(0.5), radius: 3)
                            }
                        }
                    } icon: {
                        Image(systemName: "mic")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .tag(Panel.record)

                    Label {
                        HStack {
                            Text("Action Items").font(Theme.body)
                            if openActionCount > 0 {
                                Spacer()
                                Text("\(openActionCount)")
                                    .font(Theme.meta)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "checklist")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .tag(Panel.tasks)
                }

                if !filteredMeetings.isEmpty {
                    Section {
                        ForEach(filteredMeetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(Panel.meeting(meeting.id))
                                .contextMenu {
                                    Button(role: .destructive) {
                                        delete(meeting)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        SectionLabel("Meetings")
                    }
                } else if !searchText.isEmpty {
                    Section {
                        Text("No matches")
                            .font(Theme.sub)
                            .foregroundStyle(.tertiary)
                    } header: {
                        SectionLabel("Meetings")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
            .navigationTitle("LocalScribe")
            .frame(minWidth: 240)
        } detail: {
            Group {
                switch selection {
                case .tasks:
                    TasksView()
                case .meeting(let id):
                    if let meeting = store.meetings.first(where: { $0.id == id }) {
                        MeetingDetailView(meeting: meeting)
                    } else {
                        ContentUnavailableView("Meeting not found",
                                               systemImage: "questionmark.folder")
                    }
                default:
                    RecordingView(monitor: monitor)
                }
            }
            .background(Theme.background)
        }
        .tint(Theme.accent)
        .onAppear {
            if !settings.hasOnboarded { showOnboarding = true }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                settings.hasOnboarded = true
                showOnboarding = false
            }
        }
    }

    /// Meetings filtered by the search box — matches title, notes, or any
    /// transcript line. Empty query returns everything.
    private var filteredMeetings: [Meeting] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.meetings }
        return store.meetings.filter { meeting in
            meeting.title.lowercased().contains(q)
                || meeting.notes.lowercased().contains(q)
                || (meeting.tags ?? []).contains { $0.lowercased().contains(q) }
                || meeting.lines.contains { $0.text.lowercased().contains(q) }
        }
    }

    private var openActionCount: Int {
        store.meetings.reduce(0) { $0 + $1.openActionItems.count }
    }

    private func delete(_ meeting: Meeting) {
        if selection == .meeting(meeting.id) { selection = .record }
        store.delete(meeting)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(Theme.body)
                .lineLimit(1)
            HStack(spacing: 5) {
                Text(meeting.date, style: .date)
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
                if meeting.hasNotes {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            if let tags = meeting.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        TagChip(text: tag)
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}
