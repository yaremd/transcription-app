import SwiftUI

/// Full-height "notes ↔ transcript" workspace, shown in a sheet from the saved
/// meeting so the transcript has room to scroll. The user's timestamped notes
/// on the left, the full transcript on the right — the same pairing they had
/// live. Clicking a note's time scrolls the transcript to that moment and
/// highlights it; tapping a transcript line anchors the next note you add.
/// Notes are editable, add-able, and delete-able here, and every change is
/// persisted back into the meeting (debounced). The transcript is read-only.
struct MeetingNotesWorkspace: View {
    let meeting: Meeting
    /// A moment to jump to as soon as the workspace appears — set when the
    /// sheet is opened by clicking a note in the meeting page.
    var initialJump: Date? = nil
    @EnvironmentObject private var store: MeetingStore

    /// A local, editable copy of the user's notes. Seeded from the meeting and
    /// written back (debounced) on change, so typing doesn't hit disk per key.
    @State private var blocks: [NoteBlock] = []
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    /// The moment a clicked note points at — drives the transcript's scroll +
    /// highlight (via `jumpPulse`, bumped so the pane re-runs even when the same
    /// note is clicked twice).
    @State private var jumpDate: Date?
    @State private var jumpPulse = 0
    /// Where a newly added note attaches: the transcript line the user last
    /// tapped. Nil until they pick one — then new notes default to the start.
    @State private var anchor: Date?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            notesColumn
                .frame(width: 340)
                .frame(maxHeight: .infinity)
            MeetingTranscriptColumn(meeting: meeting,
                                    jumpDate: jumpDate,
                                    jumpPulse: jumpPulse,
                                    onAnchor: { anchor = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: meeting.id, initial: true) { _, _ in
            blocks = meeting.noteBlocks ?? []
            draft = ""
            jumpDate = nil
            anchor = nil
        }
        .onChange(of: blocks) { _, _ in scheduleSave() }
        .onAppear {
            guard let initialJump else { return }
            // Deferred so the transcript's scroll view is laid out before we
            // ask it to scroll — otherwise the jump lands on nothing.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                jumpTo(initialJump)
            }
        }
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
                            EditableNoteRow(block: $block,
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
        blocks.append(NoteBlock(text: NoteMark.normalized(text), at: at))
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
            // Checkbox notes flow into the meeting's action items.
            updated.syncActionItems(fromNoteBlocks: snapshot)
            store.save(updated)
        }
    }

    private static func time(_ date: Date) -> String {
        EditableNoteRow.timeFormatter.string(from: date)
    }
}

// MARK: - Transcript column (right)

/// The saved transcript beside the notes: read-only, but each line is tappable
/// to anchor the next note to that moment. Scrolls to and highlights the lines
/// around a clicked note's time. Lines saved before timestamps existed fall
/// back to an even estimate across the meeting's duration, so anchoring still
/// works approximately on older meetings.
private struct MeetingTranscriptColumn: View {
    let meeting: Meeting
    let jumpDate: Date?
    let jumpPulse: Int
    let onAnchor: (Date) -> Void

    @EnvironmentObject private var store: MeetingStore
    @State private var highlighted: Set<UUID> = []
    @State private var tapped: UUID?
    @State private var justCopied = false
    /// The identified voice being renamed via a row's context menu, if any.
    @State private var renamingVoice: String?
    @State private var renameDraft = ""

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
                Button {
                    copyToPasteboard(meeting.transcriptText)
                    justCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        justCopied = false
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(justCopied ? Theme.green : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(lines.isEmpty)
                .help("Copy the transcript")
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
                            TranscriptRow(speaker: meeting.displayLabel(for: line),
                                          text: line.text,
                                          // A voice change is a speaker change even when the
                                          // raw label ("Others") stays the same.
                                          showSpeaker: index == 0
                                              || lines[index - 1].speaker != line.speaker
                                              || lines[index - 1].voice != line.voice,
                                          highlighted: highlighted.contains(line.id) || tapped == line.id,
                                          isYou: line.speaker == "You")
                                .id(line.id)
                                .contentShape(Rectangle())
                                .onTapGesture { anchorTo(index) }
                                .contextMenu {
                                    if let voice = line.voice {
                                        Button("Name \(meeting.displayLabel(for: line))…") {
                                            renamingVoice = voice
                                            renameDraft = meeting.speakerNames?[voice] ?? ""
                                        }
                                    }
                                }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: jumpPulse) { _, _ in jump(proxy) }
            }
        }
        .insetPanel(radius: 8)
        // Naming an identified voice: the name lands in speakerNames keyed by
        // the voice ("S2"), so every line of that voice — and the notes'
        // participants header — picks it up at once.
        .alert("Who is this?",
               isPresented: Binding(get: { renamingVoice != nil },
                                    set: { if !$0 { renamingVoice = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let voice = renamingVoice,
                   var updated = store.meetings.first(where: { $0.id == meeting.id }) {
                    var names = updated.speakerNames ?? [:]
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { names.removeValue(forKey: voice) } else { names[voice] = trimmed }
                    updated.speakerNames = names
                    store.save(updated)
                }
                renamingVoice = nil
            }
            Button("Cancel", role: .cancel) { renamingVoice = nil }
        } message: {
            Text("Every line this voice speaks will show the name, and the notes will use it.")
        }
    }

    /// Each line's time: its real commit time, or — for meetings saved before
    /// timestamps were kept — an even estimate spread across the duration.
    private func effectiveTime(_ index: Int) -> Date {
        if let at = lines[index].at { return at }
        guard lines.count > 1, meeting.duration > 0 else { return meeting.date }
        let frac = Double(index) / Double(lines.count - 1)
        return meeting.date.addingTimeInterval(meeting.duration * frac)
    }

    /// Tapping a line anchors the next note to it and flashes it briefly so the
    /// choice is visible.
    private func anchorTo(_ index: Int) {
        onAnchor(effectiveTime(index))
        let id = lines[index].id
        tapped = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if tapped == id { tapped = nil }
        }
    }

    /// Scrolls to the line at (or just before) the clicked note's time and
    /// highlights everything within ~6s of it, then fades.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let jumpDate, !lines.isEmpty else { return }
        var targetIndex = 0
        for i in lines.indices where effectiveTime(i) <= jumpDate { targetIndex = i }
        let targetAt = effectiveTime(targetIndex)
        highlighted = Set(lines.indices
            .filter { abs(effectiveTime($0).timeIntervalSince(targetAt)) < 6 }
            .map { lines[$0].id })
        withAnimation { proxy.scrollTo(lines[targetIndex].id, anchor: .center) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { highlighted = [] }
        }
    }
}
