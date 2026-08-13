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
    @EnvironmentObject private var entitlements: EntitlementService

    private let generator = NotesGenerator()
    /// The on-device notes model's download status — so the very first notes
    /// generation shows real download progress instead of an opaque spinner.
    @ObservedObject private var embeddedStatus = EmbeddedModelStatus.shared
    private static let sectionSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)

    @State private var title = ""
    @State private var notesText = ""
    @State private var editingNotes = false
    @State private var tags: [String] = []
    @State private var newTag = ""
    // Long-running model jobs are keyed by the meeting they were started for.
    // This view's @State storage survives navigating between meetings, and the
    // plain Bools these used to be leaked one meeting's "Generating…" spinner
    // (and, worse, its finished text) onto whichever meeting was open when the
    // job ended. A job shows progress only on its own meeting; the computed
    // accessors below keep every render site reading naturally.
    @State private var reshapingID: UUID?
    @State private var generatingID: UUID?
    @State private var draftingFollowUpID: UUID?
    @State private var extractingActionsID: UUID?
    @State private var generateError: String?
    @State private var templateID = NotesTemplate.general.id
    @State private var followUp = ""
    @State private var followUpError: String?
    @State private var actionsError: String?
    @State private var newAction = ""
    /// Action items already checked when this meeting was opened — hidden by
    /// default so the list shows what's left, while an item checked right now
    /// stays visible (struck through) until you leave the meeting.
    @State private var completedAtOpen: Set<UUID> = []
    @State private var showCompletedActions = false

    private var generating: Bool { generatingID == meeting.id }
    private var reshaping: Bool { reshapingID == meeting.id }
    private var draftingFollowUp: Bool { draftingFollowUpID == meeting.id }
    private var extractingActions: Bool { extractingActionsID == meeting.id }
    private var polishing: Bool { polishingID == meeting.id }

    // Section collapse state — re-derived per meeting ("content decides").
    @State private var notesOpen = true
    @State private var transcriptOpen = true
    @State private var actionsOpen = true
    @State private var followUpOpen = false
    @State private var showFullTranscript = false
    @State private var copiedTranscript = false
    @State private var polishingID: UUID?
    @State private var polishError: String?
    @State private var identifyError: String?

    // The notes<->transcript workspace opens as a full-height sheet (the inline
    // box was too cramped to scroll); `workspaceJump` carries the moment to
    // scroll to when it's opened by clicking a note.
    @State private var showWorkspace = false
    @State private var showReportProblem = false
    @State private var showTemplateEditor = false
    @State private var workspaceJump: Date?
    @ObservedObject private var customTemplates = CustomTemplateStore.shared

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
                    // The Pro formats (YAR-104). Menu items can't host the
                    // .proGated overlay, so the gate lives in gatedExport and
                    // the section title carries the honesty — the Reshape
                    // menu's pattern.
                    Section(entitlements.allows(.advancedExport) ? "More formats" : "More formats — Seal Pro") {
                        Button("Export as Word (.docx)…") { gatedExport { AdvancedExporter.exportDocx(meeting) } }
                        Button("Export subtitles (.srt)…") { gatedExport { AdvancedExporter.exportSRT(meeting) } }
                        Button("Export subtitles (.vtt)…") { gatedExport { AdvancedExporter.exportVTT(meeting) } }
                    }
                    Divider()
                    Button("Report a problem…") { showReportProblem = true }
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
            completedAtOpen = Set((meeting.actionItems ?? []).filter(\.done).map(\.id))
            showCompletedActions = false
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
            maybeGenerateNotes()
        }
        .sheet(isPresented: $showWorkspace) { workspaceSheet }
        .sheet(isPresented: $showReportProblem) {
            ReportProblemView(meeting: meeting).environmentObject(store)
        }
        .sheet(isPresented: $showTemplateEditor) { TemplateEditorSheet() }
    }

    /// Menu items can't host the .proGated overlay, so the Pro exports and
    /// custom templates gate at the action, opening the upgrade sheet instead
    /// of running (YAR-103/104).
    private func gatedExport(_ export: () -> Void) {
        guard entitlements.allows(.advancedExport) else {
            return entitlements.requestUpgrade(for: .advancedExport)
        }
        export()
    }

    private func gatedTemplate(_ template: NotesTemplate) {
        guard entitlements.allows(.customTemplates) else {
            return entitlements.requestUpgrade(for: .customTemplates)
        }
        templateID = template.id
        generateNotes()
    }

    private func gatedManageTemplates() {
        guard entitlements.allows(.customTemplates) else {
            return entitlements.requestUpgrade(for: .customTemplates)
        }
        showTemplateEditor = true
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

    /// After Stop — and on any later open — fills the AI notes in automatically
    /// when the meeting has none yet, so they're ready without a button. Only
    /// generates when empty (a meeting whose notes were cleared stays clear
    /// until asked) and stays silent on failure, leaving the manual Generate
    /// button as the retry.
    private func maybeGenerateNotes() {
        guard !meeting.hasNotes, !meeting.lines.isEmpty, generatingID == nil else { return }
        generateNotes()
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
                                if !customTemplates.templates.isEmpty {
                                    Section(entitlements.allows(.customTemplates) ? "Yours" : "Yours — Seal Pro") {
                                        ForEach(customTemplates.templates) { t in
                                            Button(t.name.isEmpty ? "Untitled" : t.name) { gatedTemplate(t) }
                                        }
                                    }
                                }
                                Divider()
                                Button("Manage templates…") { gatedManageTemplates() }
                            }
                            Divider()
                            // Menu items can't host the .proGated overlay, so
                            // the gate lives in gatedReshape; the section title
                            // carries the honesty.
                            Section(entitlements.allows(.reshapeSummary) ? "Reshape" : "Reshape — Seal Pro") {
                                Button("Make shorter") { gatedReshape("Make the notes shorter and tighter.") }
                                Button("Add more detail") { gatedReshape("Expand the notes with more detail from the transcript.") }
                                Button("More formal") { gatedReshape("Rewrite in a more formal, professional tone.") }
                                Button("Bullet points") { gatedReshape("Convert the notes to concise bullet points under each heading.") }
                                Button("Plain language") { gatedReshape("Rewrite in plain, simple language.") }
                            }
                        } label: {
                            Label("Rewrite", systemImage: "sparkles")
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(generatingID != nil || reshapingID != nil)

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
                            if !customTemplates.templates.isEmpty {
                                Section(entitlements.allows(.customTemplates) ? "Yours" : "Yours — Seal Pro") {
                                    ForEach(customTemplates.templates) { t in
                                        Button(t.name.isEmpty ? "Untitled" : t.name) { gatedTemplate(t) }
                                    }
                                }
                            }
                            Divider()
                            Button("Manage templates…") { gatedManageTemplates() }
                        } label: {
                            Label("Generate Notes", systemImage: "sparkles")
                        } primaryAction: {
                            generateNotes()
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(generatingID != nil)

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
                if case .downloading(let p) = embeddedStatus.phase {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading the on-device notes model… \(Int(p * 100))%")
                            .font(Theme.sub).foregroundStyle(.secondary)
                        ProgressView(value: p).frame(maxWidth: 320)
                    }
                } else {
                    ProgressLabel(text: "Generating notes… (\(engineLabel))")
                }
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
        guard !meeting.lines.isEmpty, generatingID == nil else { return }
        let id = meeting.id
        generatingID = id
        generateError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let jotted = meeting.notesForAI
        let chosenTemplateID = templateID
        let template = NotesTemplate.byID(chosenTemplateID)
        Task {
            do {
                let result = try await generator.generate(transcript: transcript, userNotes: jotted,
                                                          template: template, languageHint: hint, backend: b)
                await MainActor.run {
                    generatingID = nil
                    // Rebase on the freshest stored copy — the user may have
                    // retitled or tagged the meeting while the model ran, and
                    // saving the captured snapshot would erase that.
                    if var updated = store.meetings.first(where: { $0.id == id }) {
                        updated.notes = result
                        updated.templateID = chosenTemplateID
                        store.save(updated)
                    }
                    // On-screen state belongs to whichever meeting is open now.
                    guard meeting.id == id else { return }
                    notesText = result
                    withAnimation(Self.sectionSpring) { notesOpen = true }
                }
            } catch {
                await MainActor.run {
                    generatingID = nil
                    if meeting.id == id { generateError = error.localizedDescription }
                }
            }
        }
    }

    private func gatedReshape(_ instruction: String) {
        guard entitlements.allows(.reshapeSummary) else {
            return entitlements.requestUpgrade(for: .reshapeSummary)
        }
        reshape(instruction)
    }

    private func reshape(_ instruction: String) {
        guard meeting.hasNotes, reshapingID == nil else { return }
        let id = meeting.id
        reshapingID = id
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let current = meeting.notes
        Task {
            do {
                let result = try await generator.reshape(currentNotes: current, transcript: transcript,
                                                         instruction: instruction, languageHint: hint, backend: b)
                await MainActor.run {
                    reshapingID = nil
                    if var updated = store.meetings.first(where: { $0.id == id }) {
                        updated.notes = result
                        store.save(updated)
                    }
                    guard meeting.id == id else { return }
                    notesText = result
                }
            } catch {
                await MainActor.run { reshapingID = nil }
            }
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Notes & transcript", isOpen: $transcriptOpen)
                if !meeting.lines.isEmpty {
                    Text("\(meeting.lines.count) lines")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if store.existingAudioURLs(for: meeting.id).system != nil,
                   meeting.lines.contains(where: { $0.speaker == "Others" }) {
                    HStack(spacing: 5) {
                        Button("Identify speakers", action: identifySpeakers)
                            .buttonStyle(.linearQuietCompact)
                            .disabled(store.identifyingSpeakers.contains(meeting.id))
                            .help("Tell the far side's voices apart in the saved call audio, so each line says who spoke")
                        ProBadge()
                    }
                    .proGated(.speakerSplit)
                }
                if store.hasAudio(for: meeting.id) {
                    HStack(spacing: 5) {
                        Button("Improve transcript", action: polishTranscript)
                            .buttonStyle(.linearQuietCompact)
                            .disabled(polishingID != nil)
                            .help("Re-transcribe the whole meeting from its saved audio with the accurate model")
                        ProBadge()
                    }
                    .proGated(.polishPass)
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

            if store.identifyingSpeakers.contains(meeting.id) {
                ProgressLabel(text: "Listening for who's who — under a minute, even for a long meeting…")
            } else if let identifyError {
                Text(identifyError).font(Theme.sub).foregroundStyle(Theme.red)
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
                    notesPreview
                    Button {
                        workspaceJump = nil
                        showWorkspace = true
                    } label: {
                        Label("Open notes & transcript", systemImage: "rectangle.split.2x1")
                    }
                    .buttonStyle(.linearQuietCompact)
                }
            }
        }
    }

    /// Tells the far side's voices apart in the saved call audio and labels
    /// the transcript's lines with them. Also how old meetings — recorded
    /// before Seal did this automatically — get their labels.
    private func identifySpeakers() {
        identifyError = nil
        let id = meeting.id
        Task {
            let problem = await SpeakerLabeler.identify(meetingID: id, store: store)
            await MainActor.run {
                if meeting.id == id { identifyError = problem }
            }
        }
    }

    /// Re-transcribes the whole meeting from its saved audio with the
    /// accurate model and replaces the lines; notes/tags/actions are kept.
    private func polishTranscript() {
        guard polishingID == nil else { return }
        let id = meeting.id
        polishingID = id
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
                    polishingID = nil
                    guard !lines.isEmpty else {
                        if meeting.id == id {
                            polishError = "The pass produced no lines — kept the original transcript."
                        }
                        return
                    }
                    if var updated = store.meetings.first(where: { $0.id == id }) {
                        updated.lines = lines
                        store.save(updated)
                        // The rebuilt lines are new objects with no voices —
                        // re-identify so the labels survive the polish.
                        Task { _ = await SpeakerLabeler.identify(meetingID: id, store: store) }
                    }
                    guard meeting.id == id else { return }
                    showFullTranscript = false
                }
            } catch {
                await MainActor.run {
                    polishingID = nil
                    if meeting.id == id { polishError = error.localizedDescription }
                }
            }
        }
    }

    // MARK: - Notes & transcript workspace

    private static let noteTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// A compact, read-only glance at the notes taken during the call, right in
    /// the page. Clicking one opens the full workspace scrolled to that moment;
    /// the "Open" button below opens it at the top.
    private var notesPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let nb = meeting.noteBlocks, !nb.isEmpty {
                ForEach(nb) { block in
                    Button {
                        workspaceJump = block.at
                        showWorkspace = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.noteTimeFormatter.string(from: block.at))
                                .font(Theme.meta).monospacedDigit()
                                .foregroundStyle(Theme.accent.opacity(0.7))
                            notePreviewBody(block)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open the transcript at this moment")
                }
            } else {
                Text("No notes were taken during this meeting. Open the workspace to add notes anchored to the transcript.")
                    .font(Theme.sub)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .insetPanel(radius: 8)
    }

    /// One preview line of a jotted note, marker-aware: checkboxes show their
    /// state, bullets their dot, starred moments their star (see NoteMark).
    @ViewBuilder
    private func notePreviewBody(_ block: NoteBlock) -> some View {
        switch NoteMark.parse(block.text) {
        case .plain(let s):
            Text(s)
                .font(Theme.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.tertiary)
                Text(s)
                    .font(Theme.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        case .task(let done, let body):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(done ? Theme.green : .secondary)
                Text(body)
                    .font(Theme.body)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        case .highlight(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.amber)
                Text(s.isEmpty ? "Marked important" : s)
                    .font(Theme.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    /// The full-height notes ↔ transcript workspace in a resizable sheet, so the
    /// transcript has room to scroll and a jump is easy to follow.
    private var workspaceSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes & transcript")
                    .font(Theme.bodyMedium)
                Spacer()
                Button("Done") { showWorkspace = false }
                    .buttonStyle(.linearPrimaryCompact)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ThemeDivider()
            MeetingNotesWorkspace(meeting: meeting, initialJump: workspaceJump)
                .environmentObject(store)
                .padding(12)
        }
        .frame(minWidth: 820, idealWidth: 1060, maxWidth: .infinity,
               minHeight: 540, idealHeight: 720, maxHeight: .infinity)
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
                if !reusableTags.isEmpty {
                    Menu {
                        ForEach(reusableTags.prefix(12), id: \.self) { tag in
                            Button(tag) { addExistingTag(tag) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a tag you've used before")
                }
            }
        }
    }

    private func addTag() {
        let typed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !typed.isEmpty else { return }
        // Reuse the library's casing when this tag already exists elsewhere,
        // so "design" and "Design" never become two tags.
        let canonical = reusableTags.first { $0.caseInsensitiveCompare(typed) == .orderedSame } ?? typed
        addExistingTag(canonical)
    }

    private func addExistingTag(_ tag: String) {
        guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        tags.append(tag)
        saveTags()
    }

    /// Tags used across the library that this meeting doesn't carry yet —
    /// most-used first, so choosing an existing tag beats retyping it.
    private var reusableTags: [String] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for m in store.meetings {
            for tag in m.tags ?? [] {
                let key = tag.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = tag }
            }
        }
        let current = Set(tags.map { $0.lowercased() })
        return counts.keys
            .filter { !current.contains($0) }
            .sorted { a, b in
                let ca = counts[a] ?? 0, cb = counts[b] ?? 0
                return ca != cb ? ca > cb : a < b
            }
            .compactMap { display[$0] }
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
                    HStack(spacing: 5) {
                        Button("Find action items") {
                            actionsOpen = true
                            extractActions()
                        }
                        .buttonStyle(.linearQuietCompact)
                        .disabled(extractingActionsID != nil)
                        ProBadge()
                    }
                    .proGated(.actionTracking)
                }
            }
            if extractingActions {
                ProgressLabel(text: "Finding action items… (\(engineLabel))")
            } else if let actionsError {
                Text(actionsError).font(Theme.sub).foregroundStyle(Theme.red)
            }

            if actionsOpen {
                let items = meeting.actionItems ?? []
                // Items finished on an earlier visit stay out of the way; what
                // you check right now stays on screen, struck through.
                let previouslyDone = items.filter { $0.done && completedAtOpen.contains($0.id) }
                let visible = showCompletedActions
                    ? items
                    : items.filter { !$0.done || !completedAtOpen.contains($0.id) }
                if items.isEmpty && !extractingActions {
                    Text("No action items yet. Find them from the transcript, or add one below.")
                        .font(Theme.body)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(visible) { item in
                            Toggle(isOn: actionBinding(item)) {
                                Text(item.text)
                                    .font(Theme.body)
                                    .strikethrough(item.done)
                                    .foregroundStyle(item.done ? .secondary : .primary)
                            }
                            .toggleStyle(.checkbox)
                        }
                        if !previouslyDone.isEmpty {
                            Button(showCompletedActions
                                   ? "Hide completed"
                                   : "Show \(previouslyDone.count) completed") {
                                withAnimation(Self.sectionSpring) { showCompletedActions.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(Theme.meta)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
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
        guard extractingActionsID == nil else { return }
        let id = meeting.id
        extractingActionsID = id
        actionsError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let notes = meeting.notes
        Task {
            do {
                let found = try await generator.extractActionItems(transcript: transcript, notes: notes, languageHint: hint, backend: b)
                await MainActor.run {
                    extractingActionsID = nil
                    // Merge into the freshest copy — the user may have added
                    // items by hand while the model ran.
                    guard var updated = store.meetings.first(where: { $0.id == id }) else { return }
                    var items = updated.actionItems ?? []
                    for text in found where !items.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
                        items.append(ActionItem(text: text))
                    }
                    updated.actionItems = items.isEmpty ? nil : items
                    store.save(updated)
                }
            } catch {
                await MainActor.run {
                    extractingActionsID = nil
                    if meeting.id == id { actionsError = error.localizedDescription }
                }
            }
        }
    }

    // MARK: - Follow-up

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Follow-up", isOpen: $followUpOpen)
                Spacer()
                HStack(spacing: 5) {
                    Button(followUp.isEmpty ? "Draft follow-up" : "Redraft") {
                        followUpOpen = true
                        draftFollowUp()
                    }
                    .buttonStyle(.linearQuietCompact)
                    .disabled(draftingFollowUpID != nil || meeting.lines.isEmpty)
                    ProBadge()
                }
                .proGated(.followUpDraft)
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
        guard draftingFollowUpID == nil else { return }
        let id = meeting.id
        draftingFollowUpID = id
        followUpError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript
        let notes = meeting.notes
        Task {
            do {
                let result = try await generator.draftFollowUp(transcript: transcript, notes: notes, languageHint: hint, backend: b)
                await MainActor.run {
                    draftingFollowUpID = nil
                    guard meeting.id == id else { return }   // drafted for a meeting no longer on screen
                    followUp = result
                    withAnimation(Self.sectionSpring) { followUpOpen = true }
                }
            } catch {
                await MainActor.run {
                    draftingFollowUpID = nil
                    if meeting.id == id { followUpError = error.localizedDescription }
                }
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
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.accent))
            .shadow(color: .black.opacity(0.20), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .help("Ask a question about this meeting")
        .proGated(.askMeeting)
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
            : .localEmbedded(model: settings.embeddedModelID)
    }

    /// Quick jobs: title + speaker-name suggestions. On device these share the
    /// one local model; with cloud they use the same cloud backend.
    private var titleBackend: NotesBackend {
        settings.usingCloudNotes
            ? backend
            : .localEmbedded(model: settings.embeddedModelID)
    }

    private var languageHint: String {
        TranscriptLanguage(rawValue: meeting.language)?.notesHint ?? "the same language as the transcript"
    }

    private var engineLabel: String {
        settings.usingCloudNotes ? "your cloud model" : "on-device AI"
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
