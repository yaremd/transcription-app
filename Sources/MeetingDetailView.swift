import SwiftUI

/// A saved meeting: its (editable) title, transcript, and (editable) notes.
/// Title saves on Return; notes save from an explicit edit mode. Both write
/// straight back to the MeetingStore.
struct MeetingDetailView: View {
    let meeting: Meeting
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: AppSettings

    private let generator = NotesGenerator()

    @State private var title = ""
    @State private var notesText = ""
    @State private var editingNotes = false
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var reshaping = false
    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false
    @State private var askError: String?
    @State private var followUp = ""
    @State private var draftingFollowUp = false
    @State private var followUpError: String?
    @State private var extractingActions = false
    @State private var actionsError: String?
    @State private var newAction = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                tagsSection
                ThemeDivider()
                transcriptSection
                ThemeDivider()
                notesSection
                ThemeDivider()
                actionItemsSection
                ThemeDivider()
                followUpSection
                ThemeDivider()
                askSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            question = ""
            answer = ""
            askError = nil
            followUp = ""
            followUpError = nil
            newAction = ""
            actionsError = nil
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

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Transcript")
            if meeting.lines.isEmpty {
                Text("No transcript.")
                    .font(Theme.body)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(meeting.lines) { line in
                    TranscriptRow(speaker: line.speaker, text: line.text, live: false)
                }
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Notes")
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
                    Button(meeting.hasNotes ? "Edit" : "Add notes") {
                        notesText = meeting.notes
                        editingNotes = true
                    }
                    .buttonStyle(.linearQuietCompact)
                }
            }

            if reshaping {
                ProgressLabel(text: "Reshaping notes… (\(engineLabel))")
            }

            if editingNotes {
                TextEditor(text: $notesText)
                    .font(Theme.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(8)
                    .insetPanel(radius: 6)
            } else if meeting.hasNotes {
                NotesView(notes: meeting.notes)
            } else {
                Text("No notes yet. Record and Generate Notes, or add them by hand.")
                    .font(Theme.body)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = meeting
        updated.title = trimmed.isEmpty ? Meeting.defaultTitle(for: meeting.date) : trimmed
        title = updated.title
        store.save(updated)
    }

    private func saveNotes() {
        var updated = meeting
        updated.notes = notesText
        store.save(updated)
        editingNotes = false
    }

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

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Ask this meeting")
            HStack(spacing: 8) {
                TextField("Ask a question about this meeting…", text: $question)
                    .linearField()
                    .onSubmit(ask)
                Button("Ask", action: ask)
                    .buttonStyle(.linearQuietCompact)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
            }
            if asking {
                ProgressLabel(text: "Thinking… (\(engineLabel))")
            } else if let askError {
                Text(askError).font(Theme.sub).foregroundStyle(Theme.red)
            } else if !answer.isEmpty {
                Text(answer)
                    .font(Theme.body)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .insetPanel(radius: 6)
            }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        asking = true
        answer = ""
        askError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.transcriptText
        Task {
            do {
                let result = try await generator.answer(question: q, transcript: transcript, languageHint: hint, backend: b)
                await MainActor.run { answer = result; asking = false }
            } catch {
                await MainActor.run { askError = error.localizedDescription; asking = false }
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

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Action items")
                Spacer()
                if !meeting.lines.isEmpty {
                    Button("Find action items", action: extractActions)
                        .buttonStyle(.linearQuietCompact)
                        .disabled(extractingActions)
                }
            }
            if extractingActions {
                ProgressLabel(text: "Finding action items… (\(engineLabel))")
            } else if let actionsError {
                Text(actionsError).font(Theme.sub).foregroundStyle(Theme.red)
            }

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

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Follow-up")
                Spacer()
                Button(followUp.isEmpty ? "Draft follow-up" : "Redraft", action: draftFollowUp)
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
            } else if !followUp.isEmpty {
                Text(followUp)
                    .font(Theme.body)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .insetPanel(radius: 6)
            } else {
                Text("Draft a ready-to-send follow-up email from this meeting. You copy it out — nothing is sent.")
                    .font(Theme.body)
                    .foregroundStyle(.tertiary)
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
                await MainActor.run { followUp = result; draftingFollowUp = false }
            } catch {
                await MainActor.run { followUpError = error.localizedDescription; draftingFollowUp = false }
            }
        }
    }

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
