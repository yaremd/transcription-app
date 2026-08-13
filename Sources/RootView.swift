import SwiftUI

/// Which pane the detail area is showing.
enum Panel: Hashable {
    case record
    case tasks
    case meeting(UUID)
}

/// Top-level layout, meeting-first: the sidebar is the library — folders
/// first (collapsible, one per project/client), then the rest grouped by
/// day — plus Action Items; recording is an *action*, not a place — the "+"
/// toolbar button (⌘N) creates a meeting and starts listening immediately.
/// While recording, the live meeting shows as a red-dot row pinned on top of
/// the sidebar. With nothing selected the detail area is a welcome screen.
/// The AudioMonitor lives here (above the detail switch) so browsing past
/// meetings never interrupts an in-progress recording.
struct RootView: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var entitlements: EntitlementService
    @State private var selection: Panel?
    @State private var searchText = ""
    @State private var showOnboarding = false
    /// One-time thank-you for beta-era installs (YAR-101).
    @AppStorage("betaThankYouShown") private var betaThankYouShown = false
    @State private var showBetaThanks = false
    /// When the Free/Pro line first reached the public beta (v0.17,
    /// 2026-08-11) — meetings older than this mark a beta-era install.
    private static let paywallEpoch = ISO8601DateFormatter().date(from: "2026-08-11T00:00:00Z")!
    /// A meeting awaiting delete confirmation — deletion is irreversible
    /// (transcript, notes, and audio), so it always asks first.
    @State private var pendingDelete: Meeting?
    /// Folder disclosure state; folders start collapsed each launch.
    @State private var expandedFolders: Set<String> = []
    /// A meeting awaiting a name for "New folder…".
    @State private var folderAssign: Meeting?
    @State private var newFolderName = ""
    /// A folder being renamed via its context menu.
    @State private var renamingFolder: String?
    @State private var renameFolderDraft = ""

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
                            ProBadge()
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

                // Folders first — a filed meeting's home. Hidden while
                // searching: results go flat below so none are missed.
                if searchText.isEmpty {
                    ForEach(folders, id: \.self) { folder in
                        Section {
                            if expandedFolders.contains(folder) {
                                ForEach(meetings(in: folder)) { meeting in
                                    MeetingRow(meeting: meeting)
                                        .tag(Panel.meeting(meeting.id))
                                        .contextMenu { meetingContextMenu(meeting) }
                                }
                            }
                        } header: {
                            folderHeader(folder)
                        }
                    }
                }

                ForEach(groupedMeetings) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting, showTime: group.showsTime)
                                .tag(Panel.meeting(meeting.id))
                                .contextMenu { meetingContextMenu(meeting) }
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
                    TasksView(openMeeting: { selection = .meeting($0) })
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
                // `.borderedProminent` hard-codes a white label, which is
                // unreadable on the lime dark-appearance accent.
                .foregroundStyle(monitor.isRunning ? Color.white : Theme.onAccent)
                .keyboardShortcut("n", modifiers: .command)
                .help(monitor.isRunning ? "Back to the live meeting" : "New meeting — starts listening right away (⌘N)")
            }
        }
        // `selection`, not `accent`: this tint reaches List row selection and
        // toggle tracks, which macOS draws with a white foreground we can't
        // override. See Theme.selection.
        .tint(Theme.selection)
        // Without this the toolbar is a vibrancy material sampling the desktop
        // behind the window — measured #282936, a violet slab sitting next to
        // the near-black sidebar. Pin it to the pane it heads instead.
        .toolbarBackground(Theme.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // A first-run banner spanning both panes while the models download:
        // real progress for the notes model, a preparing state for the (opaque)
        // speech model. Collapses to zero height once nothing is downloading.
        .safeAreaInset(edge: .top, spacing: 0) { FirstRunDownloadBanner(monitor: monitor) }
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
            settings.appearance.apply()
            // One-time note for installs that predate the Free/Pro line
            // (YAR-101): thanks, what stays free, and their free-Pro code.
            // Never for licensed installs, fresh installs, or over onboarding.
            if !betaThankYouShown, !showOnboarding, entitlements.license == nil,
               store.meetings.contains(where: { $0.date < Self.paywallEpoch }) {
                showBetaThanks = true
            }
        }
        .sheet(isPresented: $showBetaThanks, onDismiss: { betaThankYouShown = true }) {
            BetaThankYouSheet(dismiss: { showBetaThanks = false })
        }
        // Observe on-device model download progress. This does not start a
        // download — the model is fetched lazily the first time notes or a
        // title are generated (or on demand from Settings).
        .task {
            await EmbeddedModelStatus.shared.attach()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                settings.hasOnboarded = true
                showOnboarding = false
                // Fetch the notes model in the background now, so it's ready by
                // the time the first meeting ends — instead of a cold, blocking
                // download on first notes. Only when on-device notes are in use.
                if !settings.usingCloudNotes {
                    EmbeddedModelStatus.shared.startIfNeeded()
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayTitle ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let meeting = pendingDelete { delete(meeting) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The transcript, notes, and audio for this meeting will be removed from your Mac. This can't be undone.")
        }
        .alert("New folder", isPresented: Binding(get: { folderAssign != nil },
                                                  set: { if !$0 { folderAssign = nil } })) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                if let meeting = folderAssign {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { setFolder(meeting, to: name) }
                }
                folderAssign = nil
            }
            Button("Cancel", role: .cancel) { folderAssign = nil }
        } message: {
            Text("Folders group meetings by project or client in the sidebar.")
        }
        .alert("Rename folder", isPresented: Binding(get: { renamingFolder != nil },
                                                     set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $renameFolderDraft)
            Button("Rename") {
                if let old = renamingFolder { renameFolder(old, to: renameFolderDraft) }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        } message: {
            Text("Every meeting in the folder moves with it.")
        }
    }

    // MARK: - Folders

    /// Folder names in use, alphabetical. Folders exist through membership —
    /// no separate store, nothing to migrate, nothing to clean up. They're
    /// created from a meeting's "Move to folder → New folder…", so an empty
    /// folder can't exist.
    private var folders: [String] {
        Array(Set(store.meetings.compactMap(\.folder)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func meetings(in folder: String) -> [Meeting] {
        store.meetings.filter { $0.folder == folder }
    }

    /// A folder's collapsible header: chevron, name (section-label style),
    /// count. The whole row toggles; right-click renames or deletes.
    private func folderHeader(_ folder: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 1.0)) {
                if expandedFolders.contains(folder) {
                    expandedFolders.remove(folder)
                } else {
                    expandedFolders.insert(folder)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expandedFolders.contains(folder) ? 90 : 0))
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(folder.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(meetings(in: folder).count)")
                    .font(Theme.meta)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename folder…") {
                renamingFolder = folder
                renameFolderDraft = folder
            }
            Button("Delete folder") { deleteFolder(folder) }
        }
    }

    /// The right-click menu every meeting row carries: file it, or delete it.
    @ViewBuilder
    private func meetingContextMenu(_ meeting: Meeting) -> some View {
        Menu("Move to folder") {
            Button("New folder…") {
                newFolderName = ""
                folderAssign = meeting
            }
            if !folders.isEmpty { Divider() }
            ForEach(folders, id: \.self) { folder in
                Button(folder) { setFolder(meeting, to: folder) }
                    .disabled(meeting.folder == folder)
            }
            if meeting.folder != nil {
                Divider()
                Button("Remove from folder") { setFolder(meeting, to: nil) }
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = meeting
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func setFolder(_ meeting: Meeting, to folder: String?) {
        var updated = meeting
        updated.folder = folder
        store.save(updated)
        if let folder { expandedFolders.insert(folder) }
    }

    /// Deleting a folder unfiles its meetings — nothing is ever lost.
    private func deleteFolder(_ folder: String) {
        for meeting in store.meetings where meeting.folder == folder {
            var updated = meeting
            updated.folder = nil
            store.save(updated)
        }
        expandedFolders.remove(folder)
    }

    private func renameFolder(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        for meeting in store.meetings where meeting.folder == old {
            var updated = meeting
            updated.folder = name
            store.save(updated)
        }
        if expandedFolders.contains(old) {
            expandedFolders.remove(old)
            expandedFolders.insert(name)
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
                || (meeting.folder?.lowercased().contains(q) ?? false)
                || meeting.lines.contains { $0.text.lowercased().contains(q) }
        }
    }

    /// What the date-grouped library lists: with no search, the unfiled
    /// meetings (filed ones live in their folder above); while searching,
    /// every match — folders hide and the library goes flat, so a result
    /// can never be silently missing.
    private var libraryMeetings: [Meeting] {
        searchText.isEmpty ? store.meetings.filter { $0.folder == nil } : filteredMeetings
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
        for meeting in libraryMeetings {
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
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 64, height: 64)
                    .scaleEffect(breathe ? 1.12 : 1.0)
                    .opacity(breathe ? 0.7 : 1.0)
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .scaleEffect(breathe ? 1.05 : 1.0)
            }
            .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: breathe)
            .onAppear { breathe = true }
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

/// App-wide first-run banner shown while the on-device models download, so the
/// user sees "it's fetching" across every pane instead of a silent wait. The
/// notes model reports a real percentage (`EmbeddedModelStatus`); the speech
/// model's download is opaque through WhisperKit's prewarm, so it shows a
/// "preparing" state. Renders nothing once neither is in flight — zero height.
private struct FirstRunDownloadBanner: View {
    @ObservedObject var monitor: AudioMonitor
    @ObservedObject private var notes = EmbeddedModelStatus.shared

    var body: some View {
        let speechPreparing = !monitor.modelStatus.isEmpty
        let notesProgress: Double? = { if case .downloading(let p) = notes.phase { return p }; return nil }()

        if speechPreparing || notesProgress != nil {
            VStack(alignment: .leading, spacing: 8) {
                if speechPreparing {
                    row(icon: "waveform", title: "Preparing the speech model…", progress: nil)
                }
                if let p = notesProgress {
                    row(icon: "sparkles",
                        title: "Downloading the on-device notes model… \(Int(p * 100))%",
                        progress: p)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: speechPreparing)
            .animation(.easeOut(duration: 0.2), value: notesProgress != nil)
        }
    }

    @ViewBuilder
    private func row(icon: String, title: String, progress: Double?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.sub)
                    .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress).frame(maxWidth: 320)
                }
            }
            if progress == nil { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    var showTime = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(primaryText)
                .font(Theme.body)
                .lineLimit(1)
            if let secondaryText {
                Text(secondaryText)
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                Text(meeting.date, style: showTime ? .time : .date)
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

    /// A meeting the AI hasn't named yet (still the placeholder, or blank).
    private var isUnnamed: Bool {
        let t = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == Meeting.defaultTitle
    }

    /// The bold line. For a named meeting it's the title; for an unnamed one the
    /// content preview is promoted so the row is identifiable instead of a wall
    /// of identical "New transcription" labels.
    private var primaryText: String { meeting.displayTitle }

    /// The quiet second line: the preview — unless it's already the bold line.
    private var secondaryText: String? {
        guard !isUnnamed, !meeting.preview.isEmpty else { return nil }
        return meeting.preview
    }
}
