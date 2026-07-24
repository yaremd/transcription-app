import SwiftUI

/// A saved meeting, arranged the way it's actually used: notes first (with
/// Generate), the transcript as a short preview with Copy right under it,
/// then action items and the follow-up draft. Every section collapses; ones
/// with content start open, empty ones closed. "Ask this meeting" is a chat
/// docked to the bottom of the page — ephemeral, cleared on leaving.
struct MeetingDetailView: View {
    let meeting: Meeting
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var vocabulary: VocabularyStore

    private let generator = NotesGenerator()
    private static let sectionSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)

    @State private var title = ""
    @State private var notesText = ""
    @State private var editingNotes = false
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var reshaping = false
    @State private var generating = false
    @State private var generateError: String?
    @State private var templateID = NotesTemplate.general.id
    @State private var followUp = ""
    @State private var draftingFollowUp = false
    @State private var followUpError: String?
    @State private var extractingActions = false
    @State private var actionsError: String?
    @State private var newAction = ""

    // Section collapse state — re-derived per meeting ("content decides").
    @State private var notesOpen = true
    @State private var transcriptOpen = true
    @State private var actionsOpen = true
    @State private var followUpOpen = false
    @State private var showFullTranscript = false
    @State private var copiedTranscript = false
    @State private var polishing = false
    @State private var polishError: String?

    // Ephemeral chat — a floating widget, closed until opened.
    @State private var chat: [ChatMessage] = []
    @State private var chatInput = ""
    @State private var chatBusy = false
    @State private var chatOpen = false
    @FocusState private var chatFocused: Bool

    /// Speaker names the model proposed for this meeting, awaiting the user's
    /// confirmation. nil = nothing (yet) to suggest.
    @State private var suggestedNames: [String: String]?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    tagsSection
                    ThemeDivider()
                    notesSection
                    ThemeDivider()
                    transcriptSection
                    ThemeDivider()
                    actionItemsSection
                    ThemeDivider()
                    followUpSection
                    Color.clear.frame(height: 56)   // clearance for the closed Ask pill
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // "Ask this meeting" docks as its own right-hand column so it never
            // covers the notes it answers about — the page reflows beside it.
            if chatOpen && !meeting.lines.isEmpty {
                chatDock
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !chatOpen && !meeting.lines.isEmpty {
                chatLauncher
                    .padding(20)
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .navigationTitle(meeting.title)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Copy as Markdown") { MeetingExporter.copyMarkdown(meeting) }
                    Button("Copy transcript") { copyToPasteboard(meeting.transcriptText) }
                    Divider()
                    Button("Export as Markdown…") { MeetingExporter.exportMarkdown(meeting) }
                    Button("Export as PDF…") { MeetingExporter.exportPDF(meeting) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onChange(of: meeting.id, initial: true) { _, _ in
            title = meeting.title
            notesText = meeting.notes
            tags = meeting.tags ?? []
            editingNotes = false
            followUp = ""
            followUpError = nil
            newAction = ""
            actionsError = nil
            generateError = nil
            polishError = nil
            templateID = meeting.templateID ?? NotesTemplate.general.id
            // Content decides the initial state.
            notesOpen = true
            transcriptOpen = true
            actionsOpen = !(meeting.actionItems ?? []).isEmpty
            followUpOpen = false
            showFullTranscript = false
            copiedTranscript = false
            chat = []
            chatInput = ""
            chatBusy = false
            chatOpen = false
            suggestedNames = nil
            maybeSuggestTitle()
            maybeSuggestSpeakers()
        }
    }

    /// Asks the local model who was actually talking (from self-intros and
    /// address forms) the first time a meeting is opened. Proposes, never
    /// applies: the banner in the transcript section waits for the user.
    /// Silent on failure; declining is remembered (speakerNames == [:]).
    private func maybeSuggestSpeakers() {
        guard meeting.speakerNames == nil, !meeting.lines.isEmpty else { return }
        let transcript = meeting.transcriptText
        guard transcript.count >= 80 else { return }
        let id = meeting.id
        let b = titleBackend
        Task {
            guard let names = try? await generator.suggestSpeakerNames(transcript: transcript, backend: b),
                  !names.isEmpty else { return }
            await MainActor.run {
                guard meeting.id == id, meeting.speakerNames == nil else { return }
                suggestedNames = names
            }
        }
    }

    private func applySuggestedNames() {
        guard let names = suggestedNames, !names.isEmpty else { return }
        var updated = meeting
        updated.speakerNames = names
        store.save(updated)
        suggestedNames = nil
    }

    private func dismissSuggestedNames() {
        var updated = meeting
        updated.speakerNames = [:]   // remembered: asked, and the labels stay
        store.save(updated)
        suggestedNames = nil
    }

    private func suggestionLine(_ names: [String: String]) -> String {
        var parts: [String] = []
        if let others = names["Others"] { parts.append("\(others) — the other side") }
        if let you = names["You"] { parts.append("\(you) — you") }
        return "Sounds like: " + parts.joined(separator: " · ")
    }

    /// Retries naming a meeting that Stop couldn't name — e.g. the local model
    /// wasn't running then, so it kept the "New transcription" placeholder. Runs
    /// once when the meeting is opened, only ever replaces the placeholder (a
    /// title the user typed is never touched), and stays silent on failure.
    private func maybeSuggestTitle() {
        let current = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || current == Meeting.defaultTitle else { return }
        let transcript = meeting.aiTranscript
        guard transcript.count >= 80 else { return }   // too little to name well
        let id = meeting.id
        let hint = languageHint
        let b = titleBackend
        Task {
            guard let suggested = try? await generator.suggestTitle(
                transcript: transcript, languageHint: hint, backend: b) else { return }
            await MainActor.run {
                guard var m = store.meetings.first(where: { $0.id == id }) else { return }
                let existing = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard existing.isEmpty || existing == Meeting.defaultTitle else { return }
                m.title = suggested
                store.save(m)
                if meeting.id == id { title = suggested }   // reflect in the open header
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $title)
                .font(Theme.pageTitle)
                .textFieldStyle(.plain)
                .onSubmit(saveTitle)
            Text(headerMeta)
                .font(Theme.sub)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// One quiet meta line: date · duration · language (when it was fixed,
    /// not auto-detected — auto would just be noise).
    private var headerMeta: String {
        var parts = [meeting.date.formatted(date: .abbreviated, time: .shortened), durationText]
        if let lang = TranscriptLanguage(rawValue: meeting.language), lang != .auto {
            parts.append(lang.label)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Section chrome

    /// Chevron + section label; the whole leading edge toggles the section.
    private func sectionHeader(_ label: String, isOpen: Binding<Bool>) -> some View {
        Button {
            withAnimation(Self.sectionSpring) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                SectionLabel(label)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Notes", isOpen: $notesOpen)
                Spacer()
                if editingNotes {
                    Button("Cancel") {
                        notesText = meeting.notes
                        editingNotes = false
                    }
                    .buttonStyle(.linearQuietCompact)
                    Button("Save", action: saveNotes)
                        .buttonStyle(.linearPrimaryCompact)
                        .keyboardShortcut("s", modifiers: .command)
                } else if !meeting.lines.isEmpty {
                    if meeting.hasNotes {
                        // One menu for every AI rewrite: regenerate (optionally
                        // with a different template) or reshape the tone/length —
                        // instead of four separate controls competing up here.
                        Menu {
                            Button("Regenerate", action: generateNotes)
                            Menu("Regenerate as…") {
                                ForEach(NotesTemplate.all) { t in
                                    Button(t.name) { templateID = t.id; generateNotes() }
                                }
                            }
                            Divider()
                            Section("Reshape") {
                                Button("Make shorter") { reshape("Make the notes shorter and tighter.") }
                                Button("Add more detail") { reshape("Expand the notes with more detail from the transcript.") }
                                Button("More formal") { reshape("Rewrite in a more formal, professional tone.") }
                                Button("Bullet points") { reshape("Convert the notes to concise bullet points under each heading.") }
                                Button("Plain language") { reshape("Rewrite in plain, simple language.") }
                            }
                        } label: {
                            Label("Rewrite", systemImage: "sparkles")
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(generating || reshaping)

                        Button("Edit") {
                            notesText = meeting.notes
                            editingNotes = true
                            notesOpen = true
                        }
                        .buttonStyle(.linearQuietCompact)
                    } else {
                        // No notes yet: one prominent action. The click generates
                        // with the current template; the menu picks another.
                        Menu {
                            ForEach(NotesTemplate.all) { t in
                                Button(t.name) { templateID = t.id; generateNotes() }
                            }
                        } label: {
                            Label("Generate Notes", systemImage: "sparkles")
                        } primaryAction: {
                            generateNotes()
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(generating)

                        Button("Add notes") {
                            notesText = meeting.notes
                            editingNotes = true
                            notesOpen = true
                        }
                        .buttonStyle(.linearQuietCompact)
                    }
                } else {
                    // No transcript to work from — only manual notes.
                    Button(meeting.hasNotes ? "Edit" : "Add notes") {
                        notesText = meeting.notes
                        editingNotes = true
                        notesOpen = true
                    }
                    .buttonStyle(.linearQuietCompact)
                }
            }

            if generating {
                ProgressLabel(text: "Generating notes… (\(engineLabel))")
            } else if let generateError {
                Text(generateError).font(Theme.sub).foregroundStyle(Theme.red)
            }
            if reshaping {
                ProgressLabel(text: "Reshaping notes… (\(engineLabel))")
            }

            if notesOpen {
                if editingNotes {
                    TextEditor(text: $notesText)
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220)
                        .padding(8)
                        .insetPanel(radius: 6)
                } else if meeting.hasNotes {
                    NotesView(notes: meeting.notes)
                } else if !generating {
                    Text("No notes yet — Generate Notes builds them from the transcript and your jotted notes.")
                        .font(Theme.body)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = meeting
        updated.title = trimmed.isEmpty ? Meeting.defaultTitle : trimmed
        title = updated.title
        store.save(updated)
    }

    private func saveNotes() {
        var updated = meeting
        updated.notes = notesText
        store.save(updated)
        editingNotes = false
    }

    /// Builds (or rebuilds) the meeting's notes from its stored transcript and
    /// the notes the user jotted during it — available anytime.
    private func generateNotes() {
        guard !meeting.lines.isEmpty else { return }
        generating = true
        generateError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let jotted = meeting.userNotes ?? ""
        let chosenTemplateID = templateID
        let template = NotesTemplate.all.first { $0.id == chosenTemplateID } ?? .general
        Task {
            do {
                let result = try await generator.generate(transcript: transcript, userNotes: jotted,
                                                          template: template, languageHint: hint, backend: b)
                await MainActor.run {
                    var updated = meeting
                    updated.notes = result
                    updated.templateID = chosenTemplateID
                    store.save(updated)
                    notesText = result
                    generating = false
                    withAnimation(Self.sectionSpring) { notesOpen = true }
                }
            } catch {
                await MainActor.run { generateError = error.localizedDescription; generating = false }
            }
        }
    }

    private func reshape(_ instruction: String) {
        guard meeting.hasNotes else { return }
        reshaping = true
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let current = meeting.notes
        Task {
            do {
                let result = try await generator.reshape(currentNotes: current, transcript: transcript,
                                                         instruction: instruction, languageHint: hint, backend: b)
                await MainActor.run {
                    var updated = meeting
                    updated.notes = result
                    store.save(updated)
                    notesText = result
                    reshaping = false
                }
            } catch {
                await MainActor.run { reshaping = false }
            }
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Transcript", isOpen: $transcriptOpen)
                if !meeting.lines.isEmpty {
                    Text("\(meeting.lines.count) lines")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if store.hasAudio(for: meeting.id) {
                    Button("Improve transcript", action: polishTranscript)
                        .buttonStyle(.linearQuietCompact)
                        .disabled(polishing)
                        .help("Re-transcribe the whole meeting from its saved audio with the accurate model")
                }
                if !meeting.lines.isEmpty {
                    Button(copiedTranscript ? "Copied" : "Copy") {
                        copyToPasteboard(meeting.transcriptText)
                        copiedTranscript = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_400_000_000)
                            copiedTranscript = false
                        }
                    }
                    .buttonStyle(.linearQuietCompact)
                }
            }

            if polishing {
                ProgressLabel(text: "Re-transcribing with the accurate model — this takes a few minutes for long meetings…")
            } else if let polishError {
                Text(polishError).font(Theme.sub).foregroundStyle(Theme.red)
            }

            // The model thinks it heard who's who — propose, never apply.
            if let names = suggestedNames, !names.isEmpty, meeting.speakerNames == nil {
                HStack(spacing: 10) {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text(suggestionLine(names))
                        .font(Theme.sub)
                        .lineLimit(1)
                    Spacer()
                    Button("Use names", action: applySuggestedNames)
                        .buttonStyle(.linearPrimaryCompact)
                    Button("Not now", action: dismissSuggestedNames)
                        .buttonStyle(.linearQuietCompact)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .surfacePanel(radius: 6)
            }

            if transcriptOpen {
                if meeting.lines.isEmpty {
                    Text("No transcript.")
                        .font(Theme.body)
                        .foregroundStyle(.tertiary)
                } else {
                    let lines = showFullTranscript ? meeting.lines : Array(meeting.lines.prefix(4))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            TranscriptRow(speaker: meeting.displayName(for: line.speaker),
                                          text: line.text,
                                          showSpeaker: index == 0 || lines[index - 1].speaker != line.speaker,
                                          isYou: line.speaker == "You")
                        }
                    }
                    .mask(
                        // Fade the preview's tail so it reads as "there's more".
                        LinearGradient(stops: previewFade,
                                       startPoint: .top, endPoint: .bottom)
                    )
                    if meeting.lines.count > 4 {
                        Button(showFullTranscript
                               ? "Show less"
                               : "Show full transcript (\(meeting.lines.count) lines)") {
                            withAnimation(Self.sectionSpring) { showFullTranscript.toggle() }
                        }
                        .buttonStyle(.linearQuietCompact)
                    }
                }
            }
        }
    }

    /// Re-transcribes the whole meeting from its saved audio with the
    /// accurate model and replaces the lines; notes/tags/actions are kept.
    private func polishTranscript() {
        guard !polishing else { return }
        polishing = true
        polishError = nil
        let target = meeting
        let audio = store.existingAudioURLs(for: target.id)
        let terms = vocabulary.terms
        Task {
            do {
                let lines = try await TranscriptPolisher().polish(meeting: target,
                                                                  micURL: audio.mic,
                                                                  systemURL: audio.system,
                                                                  vocabulary: terms)
                await MainActor.run {
                    polishing = false
                    guard !lines.isEmpty else {
                        polishError = "The pass produced no lines — kept the original transcript."
                        return
                    }
                    var updated = target
                    updated.lines = lines
                    store.save(updated)
                    showFullTranscript = false
                }
            } catch {
                await MainActor.run {
                    polishing = false
                    polishError = error.localizedDescription
                }
            }
        }
    }

    private var previewFade: [Gradient.Stop] {
        if showFullTranscript || meeting.lines.count <= 4 {
            return [.init(color: .black, location: 0), .init(color: .black, location: 1)]
        }
        return [.init(color: .black, location: 0),
                .init(color: .black, location: 0.55),
                .init(color: .black.opacity(0.15), location: 1)]
    }

    // MARK: - Tags

    private var tagsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                ForEach(tags, id: \.self) { tag in
                    TagChip(text: tag) { removeTag(tag) }
                }
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(Theme.meta)
                    .frame(width: 90)
                    .onSubmit(addTag)
            }
        }
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !t.isEmpty,
              !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        tags.append(t)
        saveTags()
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        saveTags()
    }

    private func saveTags() {
        var updated = meeting
        updated.tags = tags.isEmpty ? nil : tags
        store.save(updated)
    }

    // MARK: - Action items

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Action items", isOpen: $actionsOpen)
                let open = meeting.openActionItems.count
                if open > 0 {
                    Text("\(open) open")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !meeting.lines.isEmpty {
                    Button("Find action items") {
                        actionsOpen = true
                        extractActions()
                    }
                    .buttonStyle(.linearQuietCompact)
                    .disabled(extractingActions)
                }
            }
            if extractingActions {
                ProgressLabel(text: "Finding action items… (\(engineLabel))")
            } else if let actionsError {
                Text(actionsError).font(Theme.sub).foregroundStyle(Theme.red)
            }

            if actionsOpen {
                let items = meeting.actionItems ?? []
                if items.isEmpty && !extractingActions {
                    Text("No action items yet. Find them from the transcript, or add one below.")
                        .font(Theme.body)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            Toggle(isOn: actionBinding(item)) {
                                Text(item.text)
                                    .font(Theme.body)
                                    .strikethrough(item.done)
                                    .foregroundStyle(item.done ? .secondary : .primary)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Add an action item…", text: $newAction)
                        .linearField()
                        .onSubmit(addAction)
                    Button("Add", action: addAction)
                        .buttonStyle(.linearQuietCompact)
                        .disabled(newAction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func actionBinding(_ item: ActionItem) -> Binding<Bool> {
        Binding(get: { item.done }, set: { setActionDone(item, done: $0) })
    }

    private func setActionDone(_ item: ActionItem, done: Bool) {
        var updated = meeting
        var items = updated.actionItems ?? []
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].done = done
        updated.actionItems = items
        store.save(updated)
    }

    private func addAction() {
        let t = newAction.trimmingCharacters(in: .whitespacesAndNewlines)
        newAction = ""
        guard !t.isEmpty else { return }
        var updated = meeting
        var items = updated.actionItems ?? []
        items.append(ActionItem(text: t))
        updated.actionItems = items
        store.save(updated)
    }

    private func extractActions() {
        extractingActions = true
        actionsError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let notes = meeting.notes
        Task {
            do {
                let found = try await generator.extractActionItems(transcript: transcript, notes: notes, languageHint: hint, backend: b)
                await MainActor.run {
                    var updated = meeting
                    var items = updated.actionItems ?? []
                    for text in found where !items.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
                        items.append(ActionItem(text: text))
                    }
                    updated.actionItems = items.isEmpty ? nil : items
                    store.save(updated)
                    extractingActions = false
                }
            } catch {
                await MainActor.run { actionsError = error.localizedDescription; extractingActions = false }
            }
        }
    }

    // MARK: - Follow-up

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Follow-up", isOpen: $followUpOpen)
                Spacer()
                Button(followUp.isEmpty ? "Draft follow-up" : "Redraft") {
                    followUpOpen = true
                    draftFollowUp()
                }
                .buttonStyle(.linearQuietCompact)
                .disabled(draftingFollowUp || meeting.lines.isEmpty)
                if !followUp.isEmpty {
                    Button("Copy") { copyToPasteboard(followUp) }
                        .buttonStyle(.linearQuietCompact)
                }
            }
            if draftingFollowUp {
                ProgressLabel(text: "Drafting… (\(engineLabel))")
            } else if let followUpError {
                Text(followUpError).font(Theme.sub).foregroundStyle(Theme.red)
            }
            if followUpOpen {
                if !followUp.isEmpty {
                    Text(followUp)
                        .font(Theme.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .insetPanel(radius: 6)
                } else if !draftingFollowUp {
                    Text("Draft a ready-to-send follow-up email from this meeting. You copy it out — nothing is sent.")
                        .font(Theme.body)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func draftFollowUp() {
        draftingFollowUp = true
        followUpError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let notes = meeting.notes
        Task {
            do {
                let result = try await generator.draftFollowUp(transcript: transcript, notes: notes, languageHint: hint, backend: b)
                await MainActor.run {
                    followUp = result
                    draftingFollowUp = false
                    withAnimation(Self.sectionSpring) { followUpOpen = true }
                }
            } catch {
                await MainActor.run { followUpError = error.localizedDescription; draftingFollowUp = false }
            }
        }
    }

    // MARK: - Chat ("Ask this meeting")

    /// The closed-state launcher: a small accent pill in the bottom-right that
    /// opens the docked chat. It covers almost nothing, so it can float.
    private var chatLauncher: some View {
        Button {
            withAnimation(Self.sectionSpring) { chatOpen = true }
            chatFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Text(chat.isEmpty ? "Ask this meeting" : "Ask · \(chat.filter { $0.role == .user }.count)")
                    .font(Theme.bodyMedium)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.accent))
            .shadow(color: .black.opacity(0.20), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .help("Ask a question about this meeting")
    }

    /// The open chat, docked as a full-height right-hand column. Because it's a
    /// real column and not an overlay, the page reflows beside it and nothing is
    /// ever hidden behind it. Header, thread, then composer — top to bottom.
    private var chatDock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Ask this meeting")
                    .font(Theme.bodyMedium)
                Spacer()
                if !chat.isEmpty {
                    Button { chat = [] } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear this conversation")
                }
                Button {
                    withAnimation(Self.sectionSpring) { chatOpen = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            ThemeDivider()

            if chat.isEmpty && !chatBusy {
                chatEmptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(chat) { message in
                                DetailChatBubble(message: message)
                            }
                            if chatBusy {
                                HStack {
                                    ProgressLabel(text: "Thinking…")
                                    Spacer()
                                }
                            }
                            Color.clear.frame(height: 1).id("chat-bottom")
                        }
                        .padding(14)
                    }
                    .onChange(of: chat.count) { _, _ in
                        withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }
                    .onChange(of: chatBusy) { _, _ in
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .frame(maxHeight: .infinity)
            }

            ThemeDivider()

            HStack(spacing: 8) {
                TextField("Ask about this meeting…", text: $chatInput)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .focused($chatFocused)
                    .onSubmit(sendChat)
                Button(action: sendChat) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(canSendChat ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSendChat)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    /// Shown before the first question: a one-liner on what Ask does, then a few
    /// tappable starter questions so nobody stares at an empty box.
    private var chatEmptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answered only from this meeting's transcript, on your Mac.")
                .font(Theme.sub)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(Self.suggestedQuestions, id: \.self) { question in
                    Button { ask(question) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                            Text(question)
                                .font(Theme.sub)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(chatBusy)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let suggestedQuestions = [
        "Summarize the key points",
        "What was decided?",
        "List the action items and owners",
        "Give me a 3-sentence recap",
    ]

    /// Fills the composer with a starter question and sends it.
    private func ask(_ question: String) {
        guard !chatBusy, !meeting.lines.isEmpty else { return }
        chatInput = question
        sendChat()
    }

    private var canSendChat: Bool {
        !chatInput.trimmingCharacters(in: .whitespaces).isEmpty && !chatBusy && !meeting.lines.isEmpty
    }

    private func sendChat() {
        guard canSendChat else { return }
        let question = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        chatInput = ""
        chat.append(ChatMessage(role: .user, text: question))
        chatBusy = true
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let meetingID = meeting.id
        Task {
            var reply: String
            do {
                reply = try await generator.answer(question: question, transcript: transcript, languageHint: hint, backend: b)
            } catch {
                reply = error.localizedDescription
            }
            await MainActor.run {
                guard meeting.id == meetingID else { return }   // navigated away
                chat.append(ChatMessage(role: .assistant, text: reply))
                chatBusy = false
            }
        }
    }

    // MARK: - Shared helpers

    /// Heavy jobs: notes, reshape, follow-up, chat.
    private var backend: NotesBackend {
        settings.usingCloudNotes
            ? .cloudOpenAICompatible(baseURL: settings.cloudBaseURL, apiKey: settings.cloudAPIKey, model: settings.cloudModel)
            : .localOllama(model: settings.resolvedNotesModel)
    }

    /// Quick jobs: title + speaker-name suggestions run on the light model.
    private var titleBackend: NotesBackend {
        settings.usingCloudNotes
            ? backend
            : .localOllama(model: settings.resolvedTitleModel)
    }

    private var languageHint: String {
        TranscriptLanguage(rawValue: meeting.language)?.notesHint ?? "the same language as the transcript"
    }

    private var engineLabel: String {
        settings.usingCloudNotes ? "your cloud model" : "\(settings.resolvedNotesModel), on your Mac"
    }

    private var durationText: String {
        let total = Int(meeting.duration)
        let m = total / 60
        let s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

// MARK: - Chat pieces

private struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

private struct DetailChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }
            Text(message.text)
                .font(Theme.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(message.role == .user ? Theme.accent.opacity(0.13) : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(message.role == .user ? Theme.accent.opacity(0.25) : Theme.border,
                                      lineWidth: 1)
                )
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

/// Small spinner + caption shown while an on-device model works.
struct ProgressLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Theme.sub)
                .foregroundStyle(.secondary)
        }
    }
}
