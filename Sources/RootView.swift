import SwiftUI

/// Which pane the detail area is showing.
enum Panel: Hashable {
    case record
    case tasks
    case meeting(UUID)
}

/// Top-level layout, meeting-first: the sidebar is the library (grouped by
/// day) plus Action Items; recording is an *action*, not a place — the "+"
/// toolbar button (⌘N) creates a meeting and starts listening immediately.
/// While recording, the live meeting shows as a red-dot row pinned on top of
/// the sidebar. With nothing selected the detail area is a welcome screen.
/// The AudioMonitor lives here (above the detail switch) so browsing past
/// meetings never interrupts an in-progress recording.
struct RootView: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: AppSettings
    @State private var selection: Panel?
    @State private var searchText = ""
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if monitor.isRunning {
                    Section {
                        Label {
                            HStack {
                                Text(monitor.isPaused ? "Paused" : "Recording…")
                                    .font(Theme.bodyMedium)
                                Spacer()
                                if !monitor.isPaused {
                                    Circle()
                                        .fill(Theme.red)
                                        .frame(width: 7, height: 7)
                                        .shadow(color: Theme.red.opacity(0.5), radius: 3)
                                }
                            }
                        } icon: {
                            Image(systemName: "record.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.red)
                        }
                        .tag(Panel.record)
                    }
                }

                Section {
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

                ForEach(groupedMeetings) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting, showTime: group.showsTime)
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
                        SectionLabel(group.title)
                    }
                }
                if filteredMeetings.isEmpty && !searchText.isEmpty {
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
            .navigationTitle("Seal")
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
                    if monitor.isRunning || selection == .record {
                        RecordingView(monitor: monitor)
                    } else {
                        WelcomeView(monitor: monitor, newMeeting: newMeeting)
                    }
                }
            }
            .background(Theme.background)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Native prominent + capsule: the toolbar draws exactly one
                // filled pill (a custom-painted background here would sit
                // inside the system's button bezel and read as a double
                // outline). tint colors it; it turns red while recording.
                Button(action: newMeeting) {
                    Label(monitor.isRunning ? "Recording…" : "New Meeting",
                          systemImage: monitor.isRunning ? "record.circle" : "plus")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(monitor.isRunning ? Theme.red : Theme.accent)
                .keyboardShortcut("n", modifiers: .command)
                .help(monitor.isRunning ? "Back to the live meeting" : "New meeting — starts listening right away (⌘N)")
            }
        }
        .tint(Theme.accent)
        // Stop saved a meeting: land on its page (notes, actions, follow-up
        // all live there). The recording screen resets when next visited.
        .onChange(of: monitor.finishedMeetingID) { _, id in
            guard let id else { return }
            selection = .meeting(id)
            monitor.finishedMeetingID = nil
        }
        // Reaching the record pane always presents a fresh screen — a
        // finished session is already saved in the library.
        .onChange(of: selection) { _, newSelection in
            if newSelection == .record { monitor.resetFinishedSession() }
        }
        .onAppear {
            if !settings.hasOnboarded { showOnboarding = true }
            // Warm the transcription model now so the first ⌘N of the app
            // run starts hearing immediately.
            monitor.prewarmModel()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                settings.hasOnboarded = true
                showOnboarding = false
            }
        }
    }

    /// "+" / ⌘N: create a meeting and start listening immediately. If one is
    /// already being recorded, just go to it.
    private func newMeeting() {
        if monitor.isRunning {
            selection = .record
            return
        }
        monitor.resetFinishedSession()
        monitor.start()
        selection = .record
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

    /// The library grouped the native way: Today, Yesterday, Previous 7 days,
    /// Older. Empty groups disappear; recent groups show times, older dates.
    private struct MeetingGroup: Identifiable {
        let id: String
        let title: String
        let showsTime: Bool
        let meetings: [Meeting]
    }

    private var groupedMeetings: [MeetingGroup] {
        let calendar = Calendar.current
        var today: [Meeting] = [], yesterday: [Meeting] = []
        var week: [Meeting] = [], older: [Meeting] = []
        for meeting in filteredMeetings {
            if calendar.isDateInToday(meeting.date) {
                today.append(meeting)
            } else if calendar.isDateInYesterday(meeting.date) {
                yesterday.append(meeting)
            } else if let days = calendar.dateComponents([.day],
                                                         from: calendar.startOfDay(for: meeting.date),
                                                         to: calendar.startOfDay(for: Date())).day,
                      days < 7 {
                week.append(meeting)
            } else {
                older.append(meeting)
            }
        }
        return [
            MeetingGroup(id: "today", title: "Today", showsTime: true, meetings: today),
            MeetingGroup(id: "yesterday", title: "Yesterday", showsTime: true, meetings: yesterday),
            MeetingGroup(id: "week", title: "Previous 7 days", showsTime: false, meetings: week),
            MeetingGroup(id: "older", title: "Older", showsTime: false, meetings: older),
        ].filter { !$0.meetings.isEmpty }
    }

    private var openActionCount: Int {
        store.meetings.reduce(0) { $0 + $1.openActionItems.count }
    }

    private func delete(_ meeting: Meeting) {
        if selection == .meeting(meeting.id) { selection = nil }
        store.delete(meeting)
    }
}

/// The calm landing state: nothing selected, no recording — one clear action.
private struct WelcomeView: View {
    @ObservedObject var monitor: AudioMonitor
    let newMeeting: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 4) {
                Text("Seal")
                    .font(Theme.pageTitle)
                Text("Private, on-device meeting notes")
                    .font(Theme.sub)
                    .foregroundStyle(.secondary)
            }
            Button("New Meeting") { newMeeting() }
                .buttonStyle(.linearPrimary)
                .padding(.top, 6)
            Text("⌘N · listening starts right away · nothing leaves your Mac")
                .font(Theme.meta)
                .foregroundStyle(.tertiary)
            if let error = monitor.errorMessage {
                Text(error)
                    .font(Theme.sub)
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    var showTime = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(Theme.body)
                .lineLimit(1)
            HStack(spacing: 5) {
                if showTime {
                    Text(meeting.date, style: .time)
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(meeting.date, style: .date)
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                }
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
