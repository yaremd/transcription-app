import SwiftUI
import AppKit

// MARK: - What the bar can do

/// One thing the Ask bar can do instead of answering a question: rewrite the
/// notes, find the action items, export a PDF. Each is reached by typing "/"
/// and a word of it, or picked from the list the bar opens when it takes
/// focus. The page that owns the bar supplies them, already gated.
struct AskBarAction: Identifiable {
    enum Group: Int, CaseIterable {
        case session, notes, meeting, transcript, share

        var title: String {
            switch self {
            case .session: return "This recording"
            case .notes: return "Notes"
            case .meeting: return "Meeting"
            case .transcript: return "Transcript"
            case .share: return "Share"
            }
        }
    }

    /// Unique, and the word typed after "/" to run it ("shorter").
    let id: String
    let title: String
    let symbol: String
    let group: Group
    var enabled = true
    /// Listed before anything is typed, so the common moves are one click away.
    var featured = false
    /// Whether the row shows its "/word". Off for families reached through
    /// another word ("Rewrite as Sales call" lives under /as).
    var showsKeyword = true
    /// The shortcut that also runs it, shown at the row's end.
    var hint: String? = nil
    /// Registered while the bar is on screen — only for actions no menu
    /// command owns already.
    var shortcut: KeyboardShortcut? = nil
    /// Instead of running: put this in the box, so the list narrows to a
    /// family ("Rewrite as…" opens the templates).
    var refine: String? = nil
    var perform: () -> Void = {}
}

/// How "/query" picks actions: a prefix of the command word first, then a
/// word of the title, then anywhere in it. Ties keep the page's own order.
/// Pure, so it is tested on its own.
enum AskBarMatch {
    static func rank(id: String, title: String, query: String) -> Int? {
        let q = normalized(query)
        if q.isEmpty { return 0 }
        let key = normalized(id)
        let name = title.lowercased()
        if key.hasPrefix(q) { return 0 }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 1 }
        if name.contains(q) || key.contains(q) { return 2 }
        return nil
    }

    static func filter(_ actions: [AskBarAction], query: String) -> [AskBarAction] {
        actions.enumerated()
            .compactMap { offset, action in
                rank(id: action.id, title: action.title, query: query).map { (action, $0, offset) }
            }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }

    /// "as-sales" and "as sales" are the same command to whoever types it.
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Asking

/// A question about one meeting: the thread grows in `AskStore` and the
/// answer streams into it. Shared by the bar, where questions are typed, and
/// the panel, whose starters ask with one click.
enum AskSession {
    @MainActor
    static func ask(_ question: String, attachments: [AskAttachment] = [], context: AskContext) {
        let store = AskStore.shared
        let id = context.meetingID
        guard !store.busy.contains(id), !context.lines().isEmpty else { return }
        store.threads[id, default: []].append(AskMessage(role: .user, text: question, attachments: attachments))
        store.threads[id, default: []].append(AskMessage(role: .assistant, text: "", streaming: true))
        store.busy.insert(id)
        let lines = context.lines()
        let text = context.transcriptText()
        let participants = context.participants()
        let documents = AskAttachmentReader.documents(from: attachments)
        let hint = context.languageHint
        let backend = context.backend
        let generator = NotesGenerator()
        Task {
            do {
                let stream = try await generator.ask(question: question, meetingID: id, lines: lines,
                                                     transcriptText: text, participants: participants,
                                                     languageHint: hint, backend: backend, documents: documents)
                for try await chunk in stream {
                    await MainActor.run { append(chunk, to: id, in: store) }
                }
                await MainActor.run { finish(id, in: store, error: nil) }
                if case .localEmbedded = backend {
                    await MLXEngine.shared.touch()   // idle counts from the answer's end
                }
            } catch {
                await MainActor.run { finish(id, in: store, error: error.localizedDescription) }
                if case .localEmbedded = backend {
                    await MLXEngine.shared.dropConversation(for: id)
                }
            }
        }
    }

    @MainActor
    private static func append(_ chunk: String, to id: UUID, in store: AskStore) {
        guard var thread = store.threads[id], let last = thread.indices.last,
              thread[last].role == .assistant else { return }
        thread[last].text += chunk
        store.threads[id] = thread
    }

    @MainActor
    private static func finish(_ id: UUID, in store: AskStore, error: String?) {
        store.busy.remove(id)
        guard var thread = store.threads[id], let last = thread.indices.last,
              thread[last].role == .assistant else { return }
        thread[last].streaming = false
        if let error {
            thread[last].text = thread[last].text.isEmpty ? error : thread[last].text + "\n\n" + error
        } else if thread[last].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thread[last].text = "No answer came back. Try asking again."
        }
        store.threads[id] = thread
    }

    /// One-click questions worth asking any meeting, for a box nobody has
    /// typed in yet.
    static func starters(live: Bool) -> [String] {
        live
            ? ["What did they just say?",
               "Summarize the meeting so far",
               "What has been decided so far?",
               "What's still open?"]
            : ["Summarize the key points",
               "What was decided?",
               "List the action items and owners",
               "Give me a 3-sentence recap"]
    }
}

// MARK: - The bar

/// The one place to talk to Seal about a meeting, floating under the page:
/// the transcript button, and a box that answers a question or, after a "/",
/// runs an action. Focused, it lists a few questions and the common actions;
/// answers stream into the companion's Ask tab beside the page. Files go
/// beside a question by the paperclip, by paste, or by drop. The live page
/// and the saved page share it, so it is learned once.
struct AskBar: View {
    let context: AskContext
    /// Whether there is anything to ask about yet. Actions work without it.
    let hasTranscript: Bool
    /// The transcript is showing beside the page: its button is lit.
    let transcriptOpen: Bool
    let toggleTranscript: () -> Void
    let actions: [AskBarAction]
    /// Brings the answer into view: the companion, on Ask.
    let showAnswers: () -> Void
    /// The question being written, shared by wherever the box is showing.
    @ObservedObject var draft: AskDraft
    /// What the page puts first in the bar: the live page's recording chip.
    var leading: AnyView? = nil
    /// Off at the foot of the Ask tab, where the Transcript tab sits right
    /// above; ⇧⌘T still works.
    var showsTranscriptButton = true
    /// The box beside the answers: it takes the cursor when a question just
    /// sent from the other one opened the conversation.
    var takesFocusRequests = false

    @EnvironmentObject private var entitlements: EntitlementService
    @ObservedObject private var store = AskStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var input: String {
        get { draft.text }
        nonmutating set { draft.text = newValue }
    }
    private var attachments: [AskAttachment] {
        get { draft.attachments }
        nonmutating set { draft.attachments = newValue }
    }
    @State private var note: String?
    @State private var height: CGFloat = 17
    @State private var focused = false
    @State private var dropTargeted = false
    /// Follows focus, but lets go a moment late, so a click on the list
    /// lands before the list goes.
    @State private var listOpen = false
    @State private var hoveringList = false
    /// Escape put the list away; it stays away until the text changes.
    @State private var dismissed = false
    /// The row the arrows or the pointer chose, as an index into `rows`.
    @State private var chosen: Int?
    @State private var focusPulse = 0
    /// Where the bar and its list are, in the window, for telling a click
    /// outside them from one inside.
    @State private var area: CGRect = .zero
    @State private var clickMonitor: Any?

    private static let buttonSize: CGFloat = 30
    private static let inset: CGFloat = 7
    private static var radius: CGFloat { buttonSize / 2 + inset }

    private var thread: [AskMessage] { store.threads[context.meetingID] ?? [] }
    private var busy: Bool { store.busy.contains(context.meetingID) }
    private var asksAllowed: Bool { entitlements.allows(.askMeeting) }

    var body: some View {
        // The list stacks above the bar rather than hanging off it: the bar
        // sits at the bottom of its column, so the column grows upward.
        VStack(spacing: 8) {
            if listVisible {
                list
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
            bar
        }
            .animation(.easeOut(duration: 0.15), value: listVisible)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { area = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, frame in area = frame }
                }
            }
            .onChange(of: focused || listVisible) { _, engaged in
                engaged ? watchClicksOutside() : stopWatchingClicks()
            }
            .onDisappear { stopWatchingClicks() }
            .onChange(of: draft.focusRequested, initial: true) { _, wanted in
                guard wanted, takesFocusRequests else { return }
                draft.focusRequested = false
                // A beat, so a box that has just appeared has its text view.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    focusPulse += 1
                }
            }
            .background { shortcutKeys }
            .onChange(of: focused) { _, now in
                if now {
                    listOpen = true
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if !focused && !hoveringList { listOpen = false }
                    }
                }
            }
            .onChange(of: input) { _, _ in
                dismissed = false
                chosen = nil
            }
            .onAppear { demoIfRequested() }
    }

    // MARK: Layout

    private var bar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                VStack(spacing: 4) {
                    ForEach(attachments) { attachment in
                        AttachmentRow(attachment: attachment) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.top, 2)
            }
            if let note {
                Text(note)
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if let leading { leading }
                if showsTranscriptButton { transcriptButton }
                GrowingTextView(text: $draft.text, height: $height, focused: $focused, dragTargeted: $dropTargeted,
                                placeholder: placeholder, focusPulse: focusPulse, maxLines: 6,
                                onSend: submit, onFiles: attach,
                                onImage: { attach(image: $0, name: "Pasted image") },
                                onRecall: { thread.last(where: { $0.role == .user })?.text },
                                onMove: move, onCancel: cancel)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    // One line sits centred on the button; more grow upward.
                    .padding(.vertical, max(0, (Self.buttonSize - height) / 2))
                trailing
            }
        }
        .padding(Self.inset)
        // A click anywhere on the bar that isn't a button puts the cursor in
        // the box, not just a click on the text itself.
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .onTapGesture { focusPulse += 1 }
        .floatingGlass(in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(ringColor, lineWidth: 1)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { AskFiles.drop($0, onFiles: attach) }
        .animation(.easeOut(duration: 0.12), value: focused)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
        .animation(.easeOut(duration: 0.12), value: height)
        .animation(.easeOut(duration: 0.15), value: note)
    }

    private var ringColor: Color {
        if dropTargeted { return Theme.accent }
        if focused { return Theme.accent.opacity(0.45) }
        // Glass alone barely shows on the panel's light ground; a hairline
        // says "type here". The pre-26 surface draws its own.
        if #available(macOS 26, *) { return Theme.border }
        return .clear
    }

    private var placeholder: String {
        guard hasTranscript && asksAllowed else { return "Type / for actions" }
        return context.live ? "Ask about what's been said, or type /" : "Ask anything, or type / for actions"
    }

    private var transcriptButton: some View {
        Button(action: toggleTranscript) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(transcriptOpen ? Theme.accent : Color.secondary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(Circle().fill(transcriptOpen ? Theme.accent.opacity(0.14) : Theme.hover))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .help(transcriptOpen ? "Hide the transcript (⇧⌘T)" : "Show the transcript (⇧⌘T)")
        .accessibilityLabel(transcriptOpen ? "Hide the transcript" : "Show the transcript")
    }

    private var trailing: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Attach a file…") { AskFiles.choose(attach) }
                Button("What's on the screen", action: attachScreen)
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: Self.buttonSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // A borderless menu draws its label in the tint; the accent is
            // kept for the lit transcript button and the send arrow.
            .tint(.secondary)
            .fixedSize()
            .help("Put a file beside your question, or paste one, or drop it on the bar. \(AskAttachmentReader.readableSummary)")

            if busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: Self.buttonSize)
                    .help("Answering…")
            } else if !input.isEmpty && command == nil {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                        .frame(width: 26, height: Self.buttonSize)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Ask (Return)")
            } else {
                Text("⌘J")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
                    .frame(height: Self.buttonSize)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
            }
        }
    }

    /// ⌘J puts the cursor in the box from anywhere on the page; actions
    /// that carry a shortcut of their own answer to it while the bar shows.
    private var shortcutKeys: some View {
        ZStack {
            Button("Ask") { focusPulse += 1 }
                .keyboardShortcut("j", modifiers: .command)
            if !showsTranscriptButton {
                Button("Transcript", action: toggleTranscript)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            ForEach(actions.filter { $0.shortcut != nil }) { action in
                Button(action.title) { if action.enabled { action.perform() } }
                    .keyboardShortcut(action.shortcut!)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: The list

    private enum Row: Identifiable {
        case question(String)
        case action(AskBarAction)

        var id: String {
            switch self {
            case .question(let text): return "q:" + text
            case .action(let action): return "a:" + action.id
            }
        }
    }

    private struct ListSection: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    /// The words after a "/", when the box holds a command rather than a question.
    private var command: String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        return String(text.dropFirst())
    }

    private var sections: [ListSection] {
        if let command {
            if command.trimmingCharacters(in: .whitespaces).isEmpty {
                // A bare "/": everything, by kind. A family's members wait
                // behind the row that opens it ("Rewrite as…").
                return AskBarAction.Group.allCases.compactMap { group in
                    let rows = actions.filter { $0.group == group && $0.showsKeyword }.map(Row.action)
                    return rows.isEmpty ? nil : ListSection(title: group.title, rows: rows)
                }
            }
            // Inside an open family ("/as "), only its members: "Export as PDF"
            // matches the word too, and is not what anyone typing "/as" means.
            // The row that opened the family is noise by then as well.
            let typed = input.trimmingCharacters(in: .whitespaces).lowercased()
            var found = AskBarMatch.filter(actions, query: command)
            if let family = actions.compactMap({ $0.refine?.trimmingCharacters(in: .whitespaces).lowercased() })
                .first(where: { typed.hasPrefix($0) }) {
                let members = String(family.dropFirst()) + "-"
                found = found.filter { $0.id.lowercased().hasPrefix(members) }
            }
            return found.isEmpty ? [] : [ListSection(title: "Actions", rows: found.map(Row.action))]
        }
        guard input.isEmpty, attachments.isEmpty else { return [] }
        var out: [ListSection] = []
        if hasTranscript && asksAllowed && !busy {
            out.append(ListSection(title: context.live ? "Ask about the meeting so far" : "Ask about this meeting",
                                   rows: AskSession.starters(live: context.live).prefix(3).map(Row.question)))
        }
        let featured = actions.filter(\.featured)
        if !featured.isEmpty {
            out.append(ListSection(title: out.isEmpty ? "Actions" : "Or do something with it",
                                   rows: featured.map(Row.action)))
        }
        return out
    }

    private var rows: [Row] { sections.flatMap(\.rows) }

    private var listVisible: Bool {
        (listOpen || hoveringList) && !dismissed && !sections.isEmpty
    }

    /// What Return runs: the row chosen, or — once a word follows "/" — the
    /// best match.
    private var highlighted: Int? {
        if let chosen, rows.indices.contains(chosen) { return chosen }
        if let command, !command.trimmingCharacters(in: .whitespaces).isEmpty, !rows.isEmpty { return 0 }
        return nil
    }

    private var list: some View {
        let all = rows
        let estimated = CGFloat(all.count) * 28 + CGFloat(sections.count) * 25 + 12
        return Group {
            if estimated > 360 {
                ScrollViewReader { proxy in
                    ScrollView { listContent }
                        .frame(height: 360)
                        .onChange(of: highlighted) { _, index in
                            guard let index, all.indices.contains(index) else { return }
                            proxy.scrollTo(all[index].id)
                        }
                }
            } else {
                listContent
            }
        }
        .floatingGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), frosted: true)
        .onHover { inside in
            hoveringList = inside
            if !inside && !focused { listOpen = false }
        }
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(sections) { section in
                Text(section.title)
                    .font(Theme.metaMedium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                    .padding(.bottom, 3)
                ForEach(section.rows) { row in
                    rowView(row, index: rows.firstIndex { $0.id == row.id } ?? 0)
                        .id(row.id)
                }
            }
        }
        .padding(6)
    }

    private func rowView(_ row: Row, index: Int) -> some View {
        let on = highlighted == index
        let enabled: Bool
        let symbol: String
        let title: String
        var trailing: String?
        switch row {
        case .question(let text):
            enabled = true
            symbol = "text.bubble"
            title = text
        case .action(let action):
            enabled = action.enabled
            symbol = action.symbol
            title = action.title
            trailing = action.hint ?? (action.showsKeyword && action.refine == nil ? "/" + action.id : nil)
        }
        return Button { run(row) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                } else if case .action(let action) = row, action.refine != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(on ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { if $0 { chosen = index } }
    }

    // MARK: Keys

    private func move(_ delta: Int) -> Bool {
        guard listVisible, !rows.isEmpty else { return false }
        if delta > 0 {
            chosen = min((highlighted ?? -1) + 1, rows.count - 1)
            return true
        }
        guard let current = highlighted else { return false }   // ↑ in a quiet box recalls the last question
        if current > 0 {
            chosen = current - 1
        } else if command == nil {
            chosen = nil
        }
        return true
    }

    /// Escape puts the list away; a second one leaves the box, the way it
    /// leaves any field, instead of opening the text view's completions.
    private func cancel() -> Bool {
        if listVisible {
            dismissed = true
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        return true
    }

    /// Return: the highlighted row if there is one, else the question.
    private func submit() {
        if listVisible, let index = highlighted, rows.indices.contains(index) {
            run(rows[index])
            return
        }
        guard command == nil else { return }   // a "/word" that matches nothing
        send()
    }

    private func run(_ row: Row) {
        switch row {
        case .question(let question):
            input = ""
            ask(question, files: [])
        case .action(let action):
            guard action.enabled else { return }
            if let refine = action.refine {
                input = refine
                return
            }
            input = ""
            listOpen = false
            hoveringList = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            action.perform()
        }
    }

    // MARK: Clicks outside

    /// A click anywhere else puts the list away and takes the cursor out of
    /// the box. Clicking the notes or the sidebar doesn't move AppKit's focus
    /// (plain text and backgrounds don't take it), so without this the list
    /// stayed open over the page until Escape. The click itself goes on to
    /// whatever it landed on; if that was another field, it keeps the cursor.
    private func watchClicksOutside() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard let window = event.window, let content = window.contentView, area != .zero else { return event }
            let location = event.locationInWindow
            let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
            guard !area.contains(point) else { return event }
            DispatchQueue.main.async {
                listOpen = false
                hoveringList = false
                chosen = nil
                if window.firstResponder is ComposerTextView {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Sending

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command == nil
            && !busy && hasTranscript && !attachments.contains(where: \.isReading)
    }

    private func send() {
        guard canSend else { return }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments.filter { $0.text != nil }
        input = ""
        attachments = []
        ask(question, files: files)
    }

    private func ask(_ question: String, files: [AskAttachment]) {
        guard asksAllowed else { return entitlements.requestUpgrade(for: .askMeeting) }
        AskSession.ask(question, attachments: files, context: context)
        showAnswers()
    }

    // MARK: Attachments

    /// Files chosen, dropped, or pasted: each is read into text right away,
    /// and the question waits until every one is read.
    private func attach(_ urls: [URL]) {
        for url in urls {
            guard attachments.count < AskAttachmentReader.maxAttachments else {
                say("Up to \(AskAttachmentReader.maxAttachments) files per question.")
                return
            }
            let item = AskAttachment(name: url.lastPathComponent, kind: AskAttachmentReader.kind(of: url))
            attachments.append(item)
            Task.detached(priority: .userInitiated) {
                let state: AskAttachment.State
                do {
                    state = .ready(try await AskAttachmentReader.read(url))
                } catch {
                    state = .failed(error.localizedDescription)
                }
                await settle(item.id, name: nil, state: state)
            }
        }
    }

    /// A picture from the pasteboard: the text on it is read, as a screen
    /// capture's is.
    private func attach(image: CGImage, name: String) {
        guard attachments.count < AskAttachmentReader.maxAttachments else {
            say("Up to \(AskAttachmentReader.maxAttachments) files per question.")
            return
        }
        let item = AskAttachment(name: name, kind: .image)
        attachments.append(item)
        Task.detached(priority: .userInitiated) {
            let state: AskAttachment.State
            do {
                let text = AskAttachmentReader.cleaned(try await ScreenTextReader.text(in: image))
                state = text.isEmpty ? .failed("No readable text on this image.") : .ready(AskAttachmentReader.clipped(text))
            } catch {
                state = .failed(error.localizedDescription)
            }
            await settle(item.id, name: nil, state: state)
        }
    }

    /// What is on the screen right now (the call's window when there is
    /// one, otherwise the display, never Seal itself), read into text and put
    /// beside the question. Nothing is kept.
    private func attachScreen() {
        guard entitlements.allows(.screenContext) else {
            entitlements.requestUpgrade(for: .screenContext)
            return
        }
        guard ScreenSnapper.hasPermission || ScreenSnapper.requestPermission() else {
            say("Allow screen capture for Seal in System Settings → Privacy & Security, then try again.")
            NSWorkspace.shared.open(ScreenSnapper.settingsURL)
            return
        }
        guard attachments.count < AskAttachmentReader.maxAttachments else {
            say("Up to \(AskAttachmentReader.maxAttachments) files per question.")
            return
        }
        let item = AskAttachment(name: "Screen", kind: .screen)
        attachments.append(item)
        Task.detached(priority: .userInitiated) {
            var name = "Screen"
            let state: AskAttachment.State
            do {
                let snapshot = try await ScreenSnapper.capture()
                if let app = snapshot.sourceApp { name = "Screen (\(app))" }
                let text = AskAttachmentReader.cleaned(try await ScreenTextReader.text(in: snapshot.image))
                state = text.isEmpty ? .failed("Nothing readable was on the screen.") : .ready(AskAttachmentReader.clipped(text))
            } catch {
                state = .failed(error.localizedDescription)
            }
            await settle(item.id, name: name, state: state)
        }
    }

    @MainActor
    private func settle(_ id: UUID, name: String?, state: AskAttachment.State) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }   // taken off meanwhile
        if let name { attachments[index].name = name }
        attachments[index].state = state
    }

    private func say(_ text: String) {
        note = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if note == text { note = nil }
        }
    }

    // MARK: Demo hooks

    /// Screenshot hooks (debug builds, isolated demo runs only): a draft in
    /// `SEAL_DEMO_ASK_DRAFT` and files in `SEAL_DEMO_ASK_ATTACH` (paths,
    /// colon-separated) fill the box without sending; `SEAL_DEMO_ASK_FOCUS=1`
    /// puts the cursor in it so its list shows; the question in
    /// `SEAL_DEMO_ASK` is asked as soon as there is a transcript and every
    /// attached file is read, so the streaming answer can be seen and measured.
    private func demoIfRequested() {
        #if DEBUG
        guard DemoMode.isActive, thread.isEmpty, !busy else { return }
        let env = ProcessInfo.processInfo.environment
        if let text = env["SEAL_DEMO_ASK_DRAFT"], !text.isEmpty, input.isEmpty { input = text }
        if let paths = env["SEAL_DEMO_ASK_ATTACH"], !paths.isEmpty, attachments.isEmpty {
            attach(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        if env["SEAL_DEMO_ASK_FOCUS"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                focusPulse += 1
            }
        }
        guard let question = env["SEAL_DEMO_ASK"], !question.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<120 where context.lines().isEmpty || attachments.contains(where: \.isReading) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !context.lines().isEmpty else { return }
            let files = attachments.filter { $0.text != nil }
            attachments = []
            ask(question, files: files)
        }
        #endif
    }
}
