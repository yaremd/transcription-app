import SwiftUI

/// One turn of an Ask conversation.
struct AskMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// The files that went with the question.
    var attachments: [AskAttachment] = []
    /// Still arriving — the reply grows as the model writes it.
    var streaming = false
}

/// Ask threads live here rather than in a page's view state, so a
/// conversation begun during the meeting is still there on its saved page
/// after Stop, and flipping between Transcript and Ask doesn't lose it. In
/// memory only: nothing about a question is ever written to disk.
final class AskStore: ObservableObject {
    static let shared = AskStore()
    @Published var threads: [UUID: [AskMessage]] = [:]
    @Published var busy: Set<UUID> = []
}

/// What a question is asked against. The closures read the transcript at
/// send time, so a question asked mid-meeting sees everything said up to
/// that second.
struct AskContext {
    let meetingID: UUID
    let live: Bool
    let languageHint: String
    let backend: NotesBackend
    /// The transcript as the on-device conversation reads it.
    let lines: () -> [AskTranscriptFeed.Line]
    /// The transcript as one block — the cloud backend, and language detection.
    let transcriptText: () -> String
    /// "PARTICIPANTS: You = Dmytro; S1 = Daniel", when names are known.
    let participants: () -> String?
}

/// The Ask half of the companion: a conversation with this meeting, answered
/// from its transcript on the Mac — during the meeting as well as after.
struct AskPanel: View {
    let context: AskContext
    /// Bumped by ⌘J so the composer takes focus.
    var focusPulse = 0

    @EnvironmentObject private var entitlements: EntitlementService
    @ObservedObject private var store = AskStore.shared
    @State private var input = ""
    /// Files beside the question being written; they go when it is sent.
    @State private var attachments: [AskAttachment] = []
    /// A line under the box for a moment — "up to 5 files".
    @State private var composerNote: String?
    private let generator = NotesGenerator()

    private var thread: [AskMessage] { store.threads[context.meetingID] ?? [] }
    private var busy: Bool { store.busy.contains(context.meetingID) }

    var body: some View {
        if entitlements.allows(.askMeeting) {
            conversation
        } else {
            locked
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if thread.isEmpty && !busy {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(thread) { message in
                                AskBubble(message: message)
                            }
                            if !busy {
                                Button("Clear conversation") { store.threads[context.meetingID] = nil }
                                    .buttonStyle(.plain)
                                    .font(Theme.meta)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.top, 4)
                            }
                            Color.clear.frame(height: 1).id("ask-bottom")
                        }
                        .padding(12)
                    }
                    .onChange(of: thread.count) { _, _ in
                        withAnimation { proxy.scrollTo("ask-bottom", anchor: .bottom) }
                    }
                    .onChange(of: thread.last?.text.count ?? 0) { _, _ in
                        proxy.scrollTo("ask-bottom", anchor: .bottom)
                    }
                }
                .frame(maxHeight: .infinity)
            }

            ThemeDivider()

            AskComposer(text: $input,
                        attachments: $attachments,
                        placeholder: context.live ? "Ask about the meeting so far…" : "Ask about this meeting…",
                        canSend: canSend,
                        focusPulse: focusPulse,
                        onSend: send,
                        onAttachFiles: attach,
                        onAttachImage: { attach(image: $0, name: "Pasted image") },
                        onAttachScreen: attachScreen,
                        lastQuestion: { thread.last(where: { $0.role == .user })?.text })
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, composerNote == nil ? 12 : 4)
            if let composerNote {
                Text(composerNote)
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: composerNote)
        .onAppear { demoAskIfRequested() }
    }

    /// Screenshot hooks (debug builds, isolated demo runs only): a draft in
    /// `SEAL_DEMO_ASK_DRAFT` and files in `SEAL_DEMO_ASK_ATTACH` (paths,
    /// colon-separated) fill the composer without sending, so the box can be
    /// seen full; the question in `SEAL_DEMO_ASK` is asked as soon as there is
    /// a transcript and every attached file is read, with those files beside
    /// it, so the streaming answer can be seen and measured.
    private func demoAskIfRequested() {
        #if DEBUG
        guard DemoMode.isActive, thread.isEmpty, !busy else { return }
        let env = ProcessInfo.processInfo.environment
        if let draft = env["SEAL_DEMO_ASK_DRAFT"], !draft.isEmpty, input.isEmpty { input = draft }
        if let paths = env["SEAL_DEMO_ASK_ATTACH"], !paths.isEmpty, attachments.isEmpty {
            attach(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        guard let question = env["SEAL_DEMO_ASK"], !question.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<120 where context.lines().isEmpty || attachments.contains(where: \.isReading) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !context.lines().isEmpty else { return }
            let files = attachments.filter { $0.text != nil }
            attachments = []
            ask(question, attachments: files)
        }
        #endif
    }

    /// Before the first question: what Ask does, and a few questions worth
    /// one click so nobody stares at an empty box.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(context.live
                 ? "Answered from the transcript so far, on your Mac — ask while it's still happening."
                 : "Answered only from this meeting's transcript, on your Mac.")
                .font(Theme.sub)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(starters, id: \.self) { question in
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
                    .disabled(busy || !hasTranscript)
                }
            }
            if !hasTranscript {
                Text(context.live ? "Waiting for the first words." : "This meeting has no transcript to ask about.")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Put a file beside a question — a plan, a slide, a photo of the whiteboard — and the answer sees it too.")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var starters: [String] {
        context.live
            ? ["What did they just say?",
               "Summarize the meeting so far",
               "What has been decided so far?",
               "What's still open?"]
            : ["Summarize the key points",
               "What was decided?",
               "List the action items and owners",
               "Give me a 3-sentence recap"]
    }

    /// Ask is on the Pro side of the line: say so, instead of a dead panel.
    private var locked: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Ask the meeting is part of Seal Pro")
                .font(Theme.bodyMedium)
            Text("What was said, what was decided, what you missed — during the meeting or after, answered from the transcript on your Mac.")
                .font(Theme.sub)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("See Seal Pro") { entitlements.requestUpgrade(for: .askMeeting) }
                .buttonStyle(.linearPrimaryCompact)
                .padding(.top, 4)
        }
        .padding(20)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Attachments

    /// Files chosen, dropped, or pasted: each is read into text right away,
    /// and the question waits until every one is read.
    private func attach(_ urls: [URL]) {
        for url in urls {
            guard attachments.count < AskAttachmentReader.maxAttachments else {
                note("Up to \(AskAttachmentReader.maxAttachments) files per question.")
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
            note("Up to \(AskAttachmentReader.maxAttachments) files per question.")
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

    /// What is on the screen right now — the call's window when there is
    /// one, otherwise the display, never Seal itself — read into text and put
    /// beside the question. Nothing is kept.
    private func attachScreen() {
        guard entitlements.allows(.screenContext) else {
            entitlements.requestUpgrade(for: .screenContext)
            return
        }
        guard ScreenSnapper.hasPermission || ScreenSnapper.requestPermission() else {
            note("Allow screen capture for Seal in System Settings → Privacy & Security, then try again.")
            NSWorkspace.shared.open(ScreenSnapper.settingsURL)
            return
        }
        guard attachments.count < AskAttachmentReader.maxAttachments else {
            note("Up to \(AskAttachmentReader.maxAttachments) files per question.")
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

    private func note(_ text: String) {
        composerNote = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if composerNote == text { composerNote = nil }
        }
    }

    // MARK: - Sending

    private var hasTranscript: Bool { !context.lines().isEmpty }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy && hasTranscript
            && !attachments.contains(where: \.isReading)
    }

    private func send() {
        guard canSend else { return }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments.filter { $0.text != nil }
        input = ""
        attachments = []
        ask(question, attachments: files)
    }

    private func ask(_ question: String, attachments: [AskAttachment] = []) {
        let id = context.meetingID
        guard !busy, hasTranscript else { return }
        store.threads[id, default: []].append(AskMessage(role: .user, text: question, attachments: attachments))
        store.threads[id, default: []].append(AskMessage(role: .assistant, text: "", streaming: true))
        store.busy.insert(id)
        let lines = context.lines()
        let text = context.transcriptText()
        let participants = context.participants()
        let documents = AskAttachmentReader.documents(from: attachments)
        let hint = context.languageHint
        let backend = context.backend
        let store = store
        Task {
            do {
                let stream = try await generator.ask(question: question, meetingID: id, lines: lines,
                                                     transcriptText: text, participants: participants,
                                                     languageHint: hint, backend: backend, documents: documents)
                for try await chunk in stream {
                    await MainActor.run { Self.append(chunk, to: id, in: store) }
                }
                await MainActor.run { Self.finish(id, in: store, error: nil) }
                if case .localEmbedded = backend {
                    await MLXEngine.shared.touch()   // idle counts from the answer's end
                }
            } catch {
                await MainActor.run { Self.finish(id, in: store, error: error.localizedDescription) }
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
}

/// One bubble: the user's on the right on an accent wash, the model's on the
/// left on a surface. A reply still being written shows a quiet spinner
/// until its first words land. The files that went with a question are
/// listed under it by name.
private struct AskBubble: View {
    let message: AskMessage

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                if message.streaming && message.text.isEmpty {
                    ProgressLabel(text: "Thinking…")
                } else {
                    Text(message.text)
                        .font(Theme.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(message.attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: attachment.kind.symbol)
                                    .font(.system(size: 9))
                                Text(attachment.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(Theme.meta)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
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
            .contextMenu {
                if !message.text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
            }
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}
