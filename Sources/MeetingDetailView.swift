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

    // Ephemeral chat.
    @State private var chat: [ChatMessage] = []
    @State private var chatInput = ""
    @State private var chatBusy = false

    var body: some View {
        ZStack(alignment: .bottom) {
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
                    Color.clear.frame(height: 90)   // room for the docked chat
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            chatDock
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
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $title)
                .font(Theme.pageTitle)
                .textFieldStyle(.plain)
                .onSubmit(saveTitle)
            Text("\(meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(durationText)")
                .font(Theme.sub)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
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
                } else {
                    if meeting.hasNotes {
                        Menu("Reshape") {
                            Button("Shorter") { reshape("Make the notes shorter and tighter.") }
                            Button("More detail") { reshape("Expand the notes with more detail from the transcript.") }
                            Button("More formal") { reshape("Rewrite in a more formal, professional tone.") }
                            Button("Bullet points") { reshape("Convert the notes to concise bullet points under each heading.") }
                            Button("Plain language") { reshape("Rewrite in plain, simple language.") }
                        }
                        .controlSize(.small)
                        .disabled(reshaping)
                        .fixedSize()
                    }
                    if !meeting.lines.isEmpty {
                        Picker("Template", selection: $templateID) {
                            ForEach(NotesTemplate.all) { t in Text(t.name).tag(t.id) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .help("Notes template")
                        Button(meeting.hasNotes ? "Regenerate" : "Generate Notes", action: generateNotes)
                            .buttonStyle(meeting.hasNotes
                                         ? LinearButtonStyle(kind: .quiet, compact: true)
                                         : LinearButtonStyle(kind: .primary, compact: true))
                            .disabled(generating || reshaping)
                    }
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
        let transcript = meeting.transcriptText
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
        let transcript = meeting.transcriptText
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

            if transcriptOpen {
                if meeting.lines.isEmpty {
                    Text("No transcript.")
                        .font(Theme.body)
                        .foregroundStyle(.tertiary)
                } else {
                    let lines = showFullTranscript ? meeting.lines : Array(meeting.lines.prefix(4))
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(lines) { line in
                            TranscriptRow(speaker: line.speaker, text: line.text, live: false)
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
        let transcript = meeting.transcriptText
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
        let transcript = meeting.transcriptText
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

    // MARK: - Chat dock ("Ask this meeting")

    /// A chat pinned to the bottom of the page, floating over the content on
    /// a translucent material. Questions go right, answers left; the thread
    /// is ephemeral and clears when leaving the meeting.
    private var chatDock: some View {
        VStack(spacing: 8) {
            if !chat.isEmpty || chatBusy {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(chat) { message in
                                DetailChatBubble(message: message)
                            }
                            if chatBusy {
                                HStack {
                                    ProgressLabel(text: "Thinking… (\(engineLabel))")
                                    Spacer()
                                }
                            }
                            Color.clear.frame(height: 1).id("chat-bottom")
                        }
                        .padding(.horizontal, 2)
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: chat.count) { _, _ in
                        withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }
                    .onChange(of: chatBusy) { _, _ in
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask about this meeting…", text: $chatInput)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .onSubmit(sendChat)
                Button(action: sendChat) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(canSendChat ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSendChat)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 680)
        .background(
            // Translucent chrome: the page scrolls beneath the chat.
            Rectangle()
                .fill(.thinMaterial)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black, location: 0.25),
                                             .init(color: .black, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, 8)
        )
        .disabled(meeting.lines.isEmpty)
        .opacity(meeting.lines.isEmpty ? 0.4 : 1)
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
        let transcript = meeting.transcriptText
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

    private var backend: NotesBackend {
        settings.usingCloudNotes
            ? .cloudOpenAICompatible(baseURL: settings.cloudBaseURL, apiKey: settings.cloudAPIKey, model: settings.cloudModel)
            : .localOllama(model: AudioMonitor.notesModel)
    }

    private var languageHint: String {
        TranscriptLanguage(rawValue: meeting.language)?.notesHint ?? "the same language as the transcript"
    }

    private var engineLabel: String {
        settings.usingCloudNotes ? "your cloud model" : "\(AudioMonitor.notesModel), on your Mac"
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
