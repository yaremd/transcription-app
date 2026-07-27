import SwiftUI

/// The saved-meeting "notes ↔ transcript" workspace: the user's own timestamped
/// notes on the left, the full transcript on the right — the same pairing they
/// had live, kept for review. Clicking a note's time highlights the moment it
/// was written; tapping a transcript line anchors the next note you add to that
/// moment. Notes are editable, add-able, and delete-able here, and every change
/// is persisted back into the meeting (debounced) — the transcript stays read-only.
struct MeetingNotesWorkspace: View {
    let meeting: Meeting
    @EnvironmentObject private var store: MeetingStore

    /// A local, editable copy of the user's notes. Seeded from the meeting and
    /// written back (debounced) on change, so typing doesn't hit disk per key.
    @State private var blocks: [NoteBlock] = []
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    /// The moment a clicked note points at — drives the transcript's scroll +
    /// highlight (via `jumpPulse`, bumped so the pane re-runs the jump even when
    /// the same note is clicked twice).
    @State private var jumpDate: Date?
    @State private var jumpPulse = 0
    /// Where a newly added note attaches: the transcript line the user last
    /// tapped. Nil until they pick one — then new notes default to the start.
    @State private var anchor: Date?
    @State private var saveTask: Task<Void, Never>?

    private static let panelHeight: CGFloat = 460

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            notesColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            MeetingTranscriptColumn(meeting: meeting,
                                    jumpDate: jumpDate,
                                    jumpPulse: jumpPulse,
                                    onAnchor: { anchor = $0 })
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.panelHeight)
        .onChange(of: meeting.id, initial: true) { _, _ in
            blocks = meeting.noteBlocks ?? []
            draft = ""
            jumpDate = nil
            anchor = nil
        }
        .onChange(of: blocks) { _, _ in scheduleSave() }
    }

    // MARK: - Notes column (left)

    private var notesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SectionLabel("My notes")
                Spacer()
                if let anchor {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill").font(.system(size: 8))
                        Text("New note → \(Self.time(anchor))")
                            .font(Theme.meta).monospacedDigit()
                    }
                    .foregroundStyle(Theme.accent.opacity(0.75))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            ThemeDivider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        if blocks.isEmpty {
                            Text("Notes you type during a call appear here, each linked to the moment you wrote it. Add one below — tap a transcript line first to attach it there.")
                                .font(Theme.sub)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 4)
                        }
                        ForEach($blocks) { $block in
                            MeetingNoteRow(block: $block,
                                           onJump: { jumpTo($0) },
                                           onDelete: { delete(block.id) })
                                .id(block.id)
                        }
                        addRow(proxy: proxy)
                            .id("note-draft")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
        }
        .insetPanel(radius: 8)
    }

    private func addRow(proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField(anchor == nil ? "Add a note…" : "Add a note at \(Self.time(anchor!))…",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($draftFocused)
                .onSubmit { add(scrollingWith: proxy) }
        }
    }

    // MARK: - Note edits

    private func add(scrollingWith proxy: ScrollViewProxy) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Attach to the tapped line, else the meeting's opening — a note must
        // always land somewhere so its time link works when reviewed later.
        let at = anchor ?? meeting.lines.first?.at ?? meeting.date
        blocks.append(NoteBlock(text: text, at: at))
        draft = ""
        draftFocused = true
        if let last = blocks.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func delete(_ id: UUID) {
        blocks.removeAll { $0.id == id }
    }

    private func jumpTo(_ date: Date) {
        jumpDate = date
        // Deferred one run-loop turn so the pane observes a real change even
        // when the same note is clicked again.
        Task { @MainActor in jumpPulse += 1 }
    }

    /// Persists note changes into the meeting, debounced so a burst of typing
    /// writes once. Rebased on the freshest copy from the store so a concurrent
    /// save (AI notes, title) is never clobbered. `userNotes` is kept in sync so
    /// the notes generator sees the latest jottings.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = blocks
        let id = meeting.id
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            var updated = store.meetings.first(where: { $0.id == id }) ?? meeting
            updated.noteBlocks = snapshot.isEmpty ? nil : snapshot
            let joined = snapshot.map(\.text).joined(separator: "\n")
            updated.userNotes = joined.isEmpty ? nil : joined
            store.save(updated)
        }
    }

    private static func time(_ date: Date) -> String {
        MeetingNoteRow.timeFormatter.string(from: date)
    }
}

// MARK: - Editable note row

/// One timestamped note in the saved meeting: a clickable time that highlights
/// the transcript moment, and its text editable in place. Delete via the
/// context menu — same shape as the live note row, but bound to a saved block.
private struct MeetingNoteRow: View {
    @Binding var block: NoteBlock
    let onJump: (Date) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(Self.timeFormatter.string(from: block.at)) { onJump(block.at) }
                .buttonStyle(.plain)
                .font(Theme.meta)
                .monospacedDigit()
                .foregroundStyle(hovering ? Theme.accent : Theme.accent.opacity(0.65))
                .help("Show what was being said at this moment")

            TextField("", text: $block.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete note", role: .destructive, action: onDelete)
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Transcript column (right)

/// The saved transcript beside the notes: read-only, but each line is tappable
/// to anchor the next note to that moment. Scrolls to and highlights the lines
/// around a clicked note's time (same behavior as the live transcript panel).
private struct MeetingTranscriptColumn: View {
    let meeting: Meeting
    let jumpDate: Date?
    let jumpPulse: Int
    let onAnchor: (Date) -> Void

    @State private var highlighted: Set<UUID> = []
    @State private var tapped: UUID?

    private var lines: [StoredLine] { meeting.lines }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SectionLabel("Transcript")
                Text("\(lines.count) lines")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("tap a line to anchor a note")
                    .font(Theme.meta)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            ThemeDivider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if lines.isEmpty {
                            Text("No transcript.")
                                .font(Theme.sub)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 12)
                        }
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            TranscriptRow(speaker: meeting.displayName(for: line.speaker),
                                          text: line.text,
                                          showSpeaker: index == 0 || lines[index - 1].speaker != line.speaker,
                                          highlighted: highlighted.contains(line.id) || tapped == line.id,
                                          isYou: line.speaker == "You")
                                .id(line.id)
                                .contentShape(Rectangle())
                                .onTapGesture { anchorTo(line) }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: jumpPulse) { _, _ in jump(proxy) }
            }
        }
        .insetPanel(radius: 8)
    }

    /// Tapping a line anchors the next note to it and flashes it briefly so the
    /// choice is visible; lines with no timestamp (older meetings) can't anchor.
    private func anchorTo(_ line: StoredLine) {
        guard let at = line.at else { return }
        onAnchor(at)
        tapped = line.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if tapped == line.id { tapped = nil }
        }
    }

    /// Scrolls to the line spoken at (or just before) the clicked note's time
    /// and highlights everything within ~6s of it, then fades.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let jumpDate, !lines.isEmpty else { return }
        let timed = lines.filter { $0.at != nil }
        guard let target = timed.last(where: { ($0.at ?? .distantPast) <= jumpDate }) ?? timed.first else { return }
        let targetAt = target.at ?? jumpDate
        highlighted = Set(timed.filter { abs(($0.at ?? .distantPast).timeIntervalSince(targetAt)) < 6 }.map(\.id))
        withAnimation { proxy.scrollTo(target.id, anchor: .center) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { highlighted = [] }
        }
    }
}
