import SwiftUI

/// A saved meeting, on the same page it was recorded on: the document — a
/// title, the notes you jotted, the write-up Seal built from them and the
/// transcript (the model's lines in muted ink, yours in ink), action items,
/// a follow-up when one has been drafted — and the companion beside it, the
/// transcript or Ask. Everything the model can do for the page lives in one
/// menu; everything about the transcript lives on the transcript.
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
    @ObservedObject private var customTemplates = CustomTemplateStore.shared
    private static let spring = MeetingPageLayout<EmptyView, EmptyView>.spring

    /// The companion's visibility and tab — preferences shared with the live
    /// page, so the choice survives Stop, new recordings, and relaunches.
    @AppStorage(CompanionPrefs.visibleKey) private var companionVisible = true
    @AppStorage(CompanionPrefs.tabKey) private var companionTabRaw = CompanionTab.transcript.rawValue

    @State private var title = ""
    @State private var editingTitle = false
    @FocusState private var titleFocused: Bool
    @State private var tags: [String] = []
    @State private var newTag = ""

    // Notes: the write-up, edited in place.
    @State private var notesText = ""
    @State private var editingNotes = false
    @FocusState private var notesFocused: Bool
    @State private var templateID = NotesTemplate.general.id
    // Long-running model jobs are keyed by the meeting they were started for.
    // This view's @State storage survives navigating between meetings, and
    // plain Bools leaked one meeting's "Generating…" spinner (and, worse, its
    // finished text) onto whichever meeting was open when the job ended.
    @State private var generatingID: UUID?
    @State private var streamingNotes = ""
    @State private var reshapingID: UUID?
    @State private var generateError: String?

    // The user's own notes, jotted during the call or added here. A local
    // editable copy, written back debounced so typing doesn't hit disk per key.
    @State private var jots: [NoteBlock] = []
    @State private var jotsFor: UUID?
    @State private var jotSaveTask: Task<Void, Never>?
    /// Where a note added here attaches: the transcript line last tapped.
    @State private var anchor: Date?

    // Action items.
    @State private var extractingActionsID: UUID?
    @State private var actionsError: String?
    @State private var newAction = ""
    /// Action items already checked when this meeting was opened — hidden by
    /// default so the list shows what's left, while an item checked right now
    /// stays visible (struck through) until you leave the meeting.
    @State private var completedAtOpen: Set<UUID> = []
    @State private var showCompletedActions = false

    // Follow-up.
    @State private var draftingFollowUpID: UUID?
    @State private var followUp = ""
    @State private var followUpError: String?

    // Transcript jobs.
    @State private var polishingID: UUID?
    @State private var polishError: String?
    @State private var identifyError: String?
    /// Speaker names the model proposed for this meeting, awaiting the user's
    /// confirmation. nil = nothing (yet) to suggest.
    @State private var suggestedNames: [String: String]?
    @State private var renamingVoice: String?
    @State private var renameDraft = ""

    // Companion.
    @State private var jumpDate: Date?
    @State private var jumpPulse = 0
    @State private var askFocusPulse = 0

    @State private var showReportProblem = false
    @State private var showTemplateEditor = false

    private var generating: Bool { generatingID == meeting.id }
    private var reshaping: Bool { reshapingID == meeting.id }
    private var draftingFollowUp: Bool { draftingFollowUpID == meeting.id }
    private var extractingActions: Bool { extractingActionsID == meeting.id }
    private var polishing: Bool { polishingID == meeting.id }

    private var companionTab: Binding<CompanionTab> {
        Binding(get: { CompanionTab(rawValue: companionTabRaw) ?? .transcript },
                set: { companionTabRaw = $0.rawValue })
    }

    var body: some View {
        MeetingPageLayout(companionVisible: companionVisible) {
            DocumentColumn { document }
        } companion: {
            CompanionPanel(tab: companionTab,
                           close: { withAnimation(Self.spring) { companionVisible = false } }) {
                transcriptPanel
            } ask: {
                AskPanel(context: askContext, focusPulse: askFocusPulse)
            }
        }
        .navigationTitle(meeting.title)
        .toolbar {
            CompanionToolbarItems(visible: companionVisible, tab: companionTab.wrappedValue,
                                  toggle: toggleCompanion)
            ToolbarItem { aiMenu }
            ToolbarItem { exportMenu }
        }
        .onChange(of: meeting.id, initial: true) { _, _ in load() }
        .onChange(of: jots) { _, _ in scheduleJotSave() }
        .onChange(of: notesFocused) { _, focused in
            if !focused && editingNotes { finishEditingNotes() }
        }
        .sheet(isPresented: $showReportProblem) {
            ReportProblemView(meeting: meeting).environmentObject(store)
        }
        .sheet(isPresented: $showTemplateEditor) { TemplateEditorSheet() }
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

    /// Fresh page state for the meeting that just came on screen.
    private func load() {
        title = meeting.title
        editingTitle = false
        notesText = meeting.notes
        editingNotes = false
        tags = meeting.tags ?? []
        newTag = ""
        templateID = meeting.templateID ?? NotesTemplate.general.id
        generateError = nil
        jots = meeting.noteBlocks ?? []
        jotsFor = meeting.id
        anchor = nil
        newAction = ""
        actionsError = nil
        completedAtOpen = Set((meeting.actionItems ?? []).filter(\.done).map(\.id))
        showCompletedActions = false
        followUp = ""
        followUpError = nil
        polishError = nil
        identifyError = nil
        suggestedNames = nil
        maybeSuggestTitle()
        maybeSuggestSpeakers()
        maybeGenerateNotes()
    }

    // MARK: - Document

    private var document: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !jots.isEmpty {
                jotList.padding(.top, 24)
            }
            notesBlock
                .padding(.top, jots.isEmpty ? 24 : 20)
            if jots.isEmpty {
                jotList.padding(.top, 18)
            }
            actionItemsSection
            if !followUp.isEmpty || draftingFollowUp || followUpError != nil {
                followUpSection
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Plain text until clicked: a live text field here takes first
            // focus whenever the window becomes key and sits there with the
            // whole title selected.
            if editingTitle {
                TextField("Untitled meeting", text: $title)
                    .font(Theme.docTitle)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit(finishEditingTitle)
                    .onExitCommand {
                        title = meeting.title
                        editingTitle = false
                    }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused && editingTitle { finishEditingTitle() }
                    }
            } else {
                Text(title.isEmpty ? "Untitled meeting" : title)
                    .font(Theme.docTitle)
                    .foregroundStyle(title.isEmpty ? .tertiary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingTitle = true
                        Task { @MainActor in titleFocused = true }
                    }
                    .help("Click to rename")
            }
            Text(headerMeta)
                .font(Theme.sub)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            tagsRow
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

    private var jotList: some View {
        JotList(blocks: $jots,
                onJump: jumpToMoment,
                onAdd: addJot,
                onDelete: { id in jots.removeAll { $0.id == id } },
                placeholder: anchor == nil ? "Add a note…" : "Add a note at \(Self.time(anchor!))…")
    }

    // MARK: - Notes

    @ViewBuilder
    private var notesBlock: some View {
        if generating {
            if !streamingNotes.isEmpty {
                NotesDocument(notes: streamingNotes, generated: streamingNotes)
                ProgressLabel(text: "Writing… (\(engineLabel))")
                    .padding(.top, 10)
            } else if case .downloading(let p) = embeddedStatus.phase {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading the on-device notes model… \(Int(p * 100))%")
                        .font(Theme.sub).foregroundStyle(.secondary)
                    ProgressView(value: p).frame(maxWidth: 320)
                }
            } else {
                ProgressLabel(text: "Writing the notes… (\(engineLabel))")
            }
        } else if editingNotes {
            VStack(alignment: .trailing, spacing: 6) {
                TextEditor(text: $notesText)
                    .font(Theme.docBody)
                    .lineSpacing(Theme.docLineSpacing)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .focused($notesFocused)
                    .frame(minHeight: 160)
                    .padding(.horizontal, -5)   // TextEditor's own inset; keep the text on the page's edge
                    .onExitCommand { finishEditingNotes() }
                Button("Done", action: finishEditingNotes)
                    .buttonStyle(.linearPrimaryCompact)
                    .keyboardShortcut("s", modifiers: .command)
            }
        } else if meeting.hasNotes {
            NotesDocument(notes: meeting.notes,
                          generated: meeting.generatedNotes,
                          fallback: meeting.lines.isEmpty ? .human : .ai)
                .contentShape(Rectangle())
                .onTapGesture { beginEditingNotes() }
                .help("Click to edit")
            if reshaping {
                ProgressLabel(text: "Reshaping… (\(engineLabel))").padding(.top, 10)
            }
            if let generateError {
                Text(generateError).font(Theme.sub).foregroundStyle(Theme.red).padding(.top, 8)
            }
        } else if !meeting.lines.isEmpty {
            // A transcript but no write-up: usually a failed first attempt —
            // auto-generation ran when the page opened.
            VStack(alignment: .leading, spacing: 10) {
                if let generateError {
                    Text(generateError).font(Theme.sub).foregroundStyle(Theme.red)
                } else {
                    Text("No notes yet.")
                        .font(Theme.docBody)
                        .foregroundStyle(.tertiary)
                }
                Button("Write the notes", action: generateNotes)
                    .buttonStyle(.linearPrimaryCompact)
            }
        }
    }

    private func beginEditingNotes() {
        guard !generating, !reshaping else { return }
        notesText = meeting.notes
        editingNotes = true
        notesFocused = true
    }

    /// Leaves edit mode and keeps what was typed. Lines that still match the
    /// model's text stay muted; anything changed is now the user's, in ink.
    private func finishEditingNotes() {
        guard editingNotes else { return }
        editingNotes = false
        notesFocused = false
        guard notesText != meeting.notes else { return }
        var updated = meeting
        updated.notes = notesText
        store.save(updated)
    }

    private func finishEditingTitle() {
        guard editingTitle else { return }
        editingTitle = false
        titleFocused = false
        saveTitle()
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = meeting
        updated.title = trimmed.isEmpty ? Meeting.defaultTitle : trimmed
        title = updated.title
        store.save(updated)
    }

    /// After Stop — and on any later open — fills the notes in automatically
    /// when the meeting has none yet, so they're ready without a button. Only
    /// generates when empty (a meeting whose notes were cleared stays clear
    /// until asked) and stays silent on failure, leaving the button as the retry.
    private func maybeGenerateNotes() {
        guard !meeting.hasNotes, !meeting.lines.isEmpty, generatingID == nil else { return }
        generateNotes()
    }

    /// Builds (or rebuilds) the meeting's notes from its stored transcript and
    /// the notes the user jotted during it — streamed onto the page as they
    /// are written.
    private func generateNotes() {
        guard !meeting.lines.isEmpty, generatingID == nil else { return }
        let id = meeting.id
        generatingID = id
        streamingNotes = ""
        generateError = nil
        editingNotes = false
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript(userName: settings.userName)
        let jotted = meeting.notesForAI
        let chosenTemplateID = templateID
        let template = NotesTemplate.byID(chosenTemplateID)
        Task {
            do {
                let result = try await generator.generate(
                    transcript: transcript, userNotes: jotted, template: template,
                    languageHint: hint, backend: b,
                    onPartial: { text in
                        Task { @MainActor in
                            if generatingID == id && meeting.id == id { streamingNotes = text }
                        }
                    })
                await MainActor.run {
                    generatingID = nil
                    streamingNotes = ""
                    // Rebase on the freshest stored copy — the user may have
                    // retitled or tagged the meeting while the model ran, and
                    // saving the captured snapshot would erase that.
                    if var updated = store.meetings.first(where: { $0.id == id }) {
                        updated.notes = result
                        updated.generatedNotes = result
                        updated.templateID = chosenTemplateID
                        store.save(updated)
                    }
                    if meeting.id == id { notesText = result }
                }
            } catch {
                await MainActor.run {
                    generatingID = nil
                    streamingNotes = ""
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
        guard meeting.hasNotes, reshapingID == nil, generatingID == nil else { return }
        let id = meeting.id
        reshapingID = id
        editingNotes = false
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript(userName: settings.userName)
        let current = meeting.notes
        Task {
            do {
                let result = try await generator.reshape(currentNotes: current, transcript: transcript,
                                                         instruction: instruction, languageHint: hint, backend: b)
                await MainActor.run {
                    reshapingID = nil
                    if var updated = store.meetings.first(where: { $0.id == id }) {
                        updated.notes = result
                        updated.generatedNotes = result
                        store.save(updated)
                    }
                    if meeting.id == id { notesText = result }
                }
            } catch {
                await MainActor.run {
                    reshapingID = nil
                    if meeting.id == id { generateError = error.localizedDescription }
                }
            }
        }
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

    // MARK: - Seal AI menu

    /// One menu for everything the model can do for this page. Menu items
    /// can't host the .proGated overlay, so each Pro action gates itself and
    /// its section title carries the honesty ("— Seal Pro").
    private var aiMenu: some View {
        Menu {
            if !meeting.lines.isEmpty {
                Section("Notes") {
                    Button(meeting.hasNotes ? "Rewrite the notes" : "Write the notes", action: generateNotes)
                        .disabled(generating || reshaping)
                    Menu(meeting.hasNotes ? "Rewrite as…" : "Write as…") {
                        ForEach(NotesTemplate.all) { t in
                            Button(t.name) { templateID = t.id; generateNotes() }
                        }
                        if !customTemplates.templates.isEmpty {
                            Section(proTitle("Yours", .customTemplates)) {
                                ForEach(customTemplates.templates) { t in
                                    Button(t.name.isEmpty ? "Untitled" : t.name) { gatedTemplate(t) }
                                }
                            }
                        }
                        Divider()
                        Button("Manage templates…") { gatedManageTemplates() }
                    }
                    .disabled(generating || reshaping)
                }
                if meeting.hasNotes {
                    Section(proTitle("Reshape", .reshapeSummary)) {
                        Button("Make shorter") { gatedReshape("Make the notes shorter and tighter.") }
                        Button("Add more detail") { gatedReshape("Expand the notes with more detail from the transcript.") }
                        Button("More formal") { gatedReshape("Rewrite in a more formal, professional tone.") }
                        Button("Bullet points") { gatedReshape("Convert the notes to concise bullet points under each heading.") }
                        Button("Plain language") { gatedReshape("Rewrite in plain, simple language.") }
                    }
                    .disabled(generating || reshaping)
                }
            }
            Section {
                Button("Edit the notes", action: beginEditingNotes)
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(generating || reshaping || editingNotes)
            }
            if !meeting.lines.isEmpty {
                Section(proTitle("Meeting", .actionTracking)) {
                    Button("Find action items") { gatedExtractActions() }
                        .disabled(extractingActions)
                    Button(followUp.isEmpty ? "Draft a follow-up" : "Redraft the follow-up") { gatedDraftFollowUp() }
                        .disabled(draftingFollowUp)
                }
                Section("Transcript") {
                    Button("Identify speakers…") { gatedIdentifySpeakers() }
                        .disabled(!canIdentifySpeakers || store.identifyingSpeakers.contains(meeting.id))
                    Button("Improve the transcript…") { gatedPolishTranscript() }
                        .disabled(!store.hasAudio(for: meeting.id) || polishing)
                }
            }
        } label: {
            Label("Seal AI", systemImage: "sparkles")
        }
        .help("Everything Seal can write for this meeting — on your Mac")
    }

    private var exportMenu: some View {
        Menu {
            Button("Copy as Markdown") { MeetingExporter.copyMarkdown(meeting) }
            Button("Copy transcript") { copyToPasteboard(meeting.transcriptText) }
            Divider()
            Button("Export as Markdown…") { MeetingExporter.exportMarkdown(meeting) }
            Button("Export as PDF…") { MeetingExporter.exportPDF(meeting) }
            Section(proTitle("More formats", .advancedExport)) {
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

    private func proTitle(_ title: String, _ feature: ProFeature) -> String {
        entitlements.allows(feature) ? title : "\(title) — Seal Pro"
    }

    private func gatedExport(_ export: () -> Void) {
        guard entitlements.allows(.advancedExport) else {
            return entitlements.requestUpgrade(for: .advancedExport)
        }
        export()
    }

    // MARK: - Jotted notes

    private func addJot(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Attach to the tapped line, else the meeting's opening — a note must
        // always land somewhere so its time link works when reviewed later.
        let at = anchor ?? meeting.lines.first?.at ?? meeting.date
        jots.append(NoteBlock(text: NoteMark.normalized(trimmed), at: at))
    }

    /// Persists note changes into the meeting, debounced so a burst of typing
    /// writes once. Rebased on the freshest copy from the store so a concurrent
    /// save (AI notes, title) is never clobbered. `userNotes` is kept in sync so
    /// the notes generator sees the latest jottings.
    private func scheduleJotSave() {
        guard jotsFor == meeting.id else { return }
        jotSaveTask?.cancel()
        let snapshot = jots
        let id = meeting.id
        jotSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard var updated = store.meetings.first(where: { $0.id == id }) else { return }
            let stored = updated.noteBlocks ?? []
            guard stored != snapshot else { return }
            updated.noteBlocks = snapshot.isEmpty ? nil : snapshot
            let joined = snapshot.map(\.text).joined(separator: "\n")
            updated.userNotes = joined.isEmpty ? nil : joined
            // Checkbox notes flow into the meeting's action items.
            updated.syncActionItems(fromNoteBlocks: snapshot)
            store.save(updated)
        }
    }

    /// Opens the companion on `target`, or closes it when that tab is already
    /// showing. Opening Ask puts the cursor in its composer.
    private func toggleCompanion(_ target: CompanionTab) {
        withAnimation(Self.spring) {
            if companionVisible && companionTab.wrappedValue == target {
                companionVisible = false
            } else {
                companionTab.wrappedValue = target
                companionVisible = true
                if target == .ask { askFocusPulse += 1 }
            }
        }
    }

    /// A note's time label was clicked: show the transcript at that moment.
    private func jumpToMoment(_ date: Date) {
        withAnimation(Self.spring) {
            companionTab.wrappedValue = .transcript
            companionVisible = true
        }
        jumpDate = date
        Task { @MainActor in jumpPulse += 1 }
    }

    private static func time(_ date: Date) -> String {
        EditableNoteRow.timeFormatter.string(from: date)
    }

    // MARK: - Tags

    private var tagsRow: some View {
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
        .padding(.top, 4)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DocumentSectionLabel("Action items")
                let open = meeting.openActionItems.count
                if open > 0 {
                    Text("\(open) open")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 28)
                        .padding(.bottom, 10)
                }
                Spacer()
                if !meeting.lines.isEmpty && (meeting.actionItems ?? []).isEmpty && !extractingActions {
                    HStack(spacing: 5) {
                        Button("Find action items") { extractActions() }
                            .buttonStyle(.linearQuietCompact)
                        ProBadge()
                    }
                    .proGated(.actionTracking)
                    .padding(.top, 28)
                    .padding(.bottom, 10)
                }
            }
            if extractingActions {
                ProgressLabel(text: "Finding action items… (\(engineLabel))")
            } else if let actionsError {
                Text(actionsError).font(Theme.sub).foregroundStyle(Theme.red)
            }

            let items = meeting.actionItems ?? []
            // Items finished on an earlier visit stay out of the way; what you
            // check right now stays on screen, struck through.
            let previouslyDone = items.filter { $0.done && completedAtOpen.contains($0.id) }
            let visible = showCompletedActions
                ? items
                : items.filter { !$0.done || !completedAtOpen.contains($0.id) }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(visible) { item in
                    Toggle(isOn: actionBinding(item)) {
                        Text(item.text)
                            .font(Theme.docSmall)
                            .strikethrough(item.done)
                            .foregroundStyle(item.done ? .secondary : .primary)
                    }
                    .toggleStyle(.checkbox)
                }
                if !previouslyDone.isEmpty {
                    Button(showCompletedActions
                           ? "Hide completed"
                           : "Show \(previouslyDone.count) completed") {
                        withAnimation(Self.spring) { showCompletedActions.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField("Add an action item…", text: $newAction)
                    .textFieldStyle(.plain)
                    .font(Theme.docSmall)
                    .onSubmit(addAction)
            }
            .padding(.top, items.isEmpty ? 0 : 4)
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

    private func gatedExtractActions() {
        guard entitlements.allows(.actionTracking) else {
            return entitlements.requestUpgrade(for: .actionTracking)
        }
        extractActions()
    }

    private func extractActions() {
        guard extractingActionsID == nil else { return }
        let id = meeting.id
        extractingActionsID = id
        actionsError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript(userName: settings.userName)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DocumentSectionLabel("Follow-up")
                Spacer()
                if !followUp.isEmpty {
                    Button("Copy") { copyToPasteboard(followUp) }
                        .buttonStyle(.linearQuietCompact)
                        .padding(.top, 28)
                        .padding(.bottom, 10)
                }
            }
            if draftingFollowUp {
                ProgressLabel(text: "Drafting… (\(engineLabel))")
            } else if let followUpError {
                Text(followUpError).font(Theme.sub).foregroundStyle(Theme.red)
            }
            if !followUp.isEmpty {
                Text(followUp)
                    .font(Theme.docBody)
                    .foregroundStyle(Theme.inkAI)
                    .lineSpacing(Theme.docLineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Drafted from the meeting. You copy it out — nothing is sent.")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func gatedDraftFollowUp() {
        guard entitlements.allows(.followUpDraft) else {
            return entitlements.requestUpgrade(for: .followUpDraft)
        }
        draftFollowUp()
    }

    private func draftFollowUp() {
        guard draftingFollowUpID == nil, !meeting.lines.isEmpty else { return }
        let id = meeting.id
        draftingFollowUpID = id
        followUpError = nil
        let b = backend
        let hint = languageHint
        let transcript = meeting.aiTranscript(userName: settings.userName)
        let notes = meeting.notes
        Task {
            do {
                let result = try await generator.draftFollowUp(transcript: transcript, notes: notes, languageHint: hint, backend: b)
                await MainActor.run {
                    draftingFollowUpID = nil
                    guard meeting.id == id else { return }   // drafted for a meeting no longer on screen
                    followUp = result
                }
            } catch {
                await MainActor.run {
                    draftingFollowUpID = nil
                    if meeting.id == id { followUpError = error.localizedDescription }
                }
            }
        }
    }

    // MARK: - Transcript companion

    private var transcriptPanel: some View {
        let order = meeting.voiceOrder
        let items = meeting.lines.map { line in
            TranscriptItem(id: line.id,
                           speaker: meeting.displayLabel(for: line),
                           text: line.text,
                           at: line.at,
                           isYou: line.speaker == "You",
                           voiceIndex: meeting.voiceIndex(for: line, in: order),
                           voice: line.voice,
                           live: false)
        }
        return TranscriptPanel(items: items,
                               recording: false,
                               jumpDate: jumpDate,
                               jumpPulse: jumpPulse,
                               fallbackStart: meeting.date,
                               fallbackDuration: meeting.duration,
                               copyText: { meeting.transcriptText },
                               onAnchor: { anchor = $0 },
                               onRenameVoice: { item in
                                   renamingVoice = item.voice
                                   renameDraft = meeting.speakerNames?[item.voice ?? ""] ?? ""
                               },
                               banner: { transcriptBanner },
                               actions: {
                                   Button("Identify speakers") { gatedIdentifySpeakers() }
                                       .disabled(!canIdentifySpeakers || store.identifyingSpeakers.contains(meeting.id))
                                   Button("Improve the transcript") { gatedPolishTranscript() }
                                       .disabled(!store.hasAudio(for: meeting.id) || polishing)
                                   if let anchor {
                                       Divider()
                                       Button("Stop attaching notes to \(Self.time(anchor))") { self.anchor = nil }
                                   }
                               })
    }

    /// What's happening to the transcript, right above it: a job in flight,
    /// its error, or the model's guess at who was talking — proposed, never
    /// applied.
    @ViewBuilder
    private var transcriptBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if polishing {
                ProgressLabel(text: "Re-transcribing with the accurate model — a few minutes for a long meeting…")
            } else if let polishError {
                Text(polishError).font(Theme.sub).foregroundStyle(Theme.red)
            }
            if store.identifyingSpeakers.contains(meeting.id) {
                ProgressLabel(text: "Listening for who's who — under a minute…")
            } else if let identifyError {
                Text(identifyError).font(Theme.sub).foregroundStyle(Theme.red)
            }
            if let names = suggestedNames, !names.isEmpty, meeting.speakerNames == nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.wave.2")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                        Text(suggestionLine(names))
                            .font(Theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        Button("Use names", action: applySuggestedNames)
                            .buttonStyle(.linearPrimaryCompact)
                        Button("Not now", action: dismissSuggestedNames)
                            .buttonStyle(.linearQuietCompact)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfacePanel(radius: 6)
            }
            if let anchor {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").font(.system(size: 8))
                    Text("New notes attach to \(Self.time(anchor))")
                        .font(Theme.meta).monospacedDigit()
                }
                .foregroundStyle(Theme.accent.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, polishing || polishError != nil || identifyError != nil
                 || store.identifyingSpeakers.contains(meeting.id)
                 || (suggestedNames?.isEmpty == false && meeting.speakerNames == nil)
                 || anchor != nil ? 8 : 0)
    }

    private var canIdentifySpeakers: Bool {
        store.existingAudioURLs(for: meeting.id).system != nil
            && meeting.lines.contains(where: { $0.speaker == "Others" })
    }

    private func gatedIdentifySpeakers() {
        guard entitlements.allows(.speakerSplit) else {
            return entitlements.requestUpgrade(for: .speakerSplit)
        }
        identifySpeakers()
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

    private func gatedPolishTranscript() {
        guard entitlements.allows(.polishPass) else {
            return entitlements.requestUpgrade(for: .polishPass)
        }
        polishTranscript()
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
                }
            } catch {
                await MainActor.run {
                    polishingID = nil
                    if meeting.id == id { polishError = error.localizedDescription }
                }
            }
        }
    }

    /// Asks the local model who was actually talking (from self-intros and
    /// address forms) the first time a meeting is opened. Proposes, never
    /// applies: the banner above the transcript waits for the user. Silent
    /// on failure; declining is remembered (speakerNames == [:]).
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
    /// wasn't ready then, so it kept the placeholder. Runs once when the
    /// meeting is opened, only ever replaces the placeholder (a title the user
    /// typed is never touched), and stays silent on failure.
    private func maybeSuggestTitle() {
        let current = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || current == Meeting.defaultTitle else { return }
        let transcript = meeting.aiTranscript(userName: settings.userName)
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

    // MARK: - Ask companion

    private var askContext: AskContext {
        let meeting = meeting
        let userName = settings.userName
        return AskContext(
            meetingID: meeting.id,
            live: false,
            languageHint: languageHint,
            backend: backend,
            lines: {
                meeting.lines.map { line in
                    var label = meeting.displayLabel(for: line)
                    if let at = line.at {
                        label = "\(AskTranscriptFeed.stamp(at.timeIntervalSince(meeting.date))) \(label)"
                    }
                    return AskTranscriptFeed.Line(id: line.id, label: label, text: line.text)
                }
            },
            transcriptText: { meeting.aiTranscript(userName: userName) },
            participants: { meeting.aiParticipants(userName: userName) })
    }

    // MARK: - Shared helpers

    /// Heavy jobs: notes, reshape, follow-up, Ask.
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
