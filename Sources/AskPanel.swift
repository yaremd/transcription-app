import SwiftUI

/// One turn of an Ask conversation.
struct AskMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
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
    @FocusState private var focused: Bool
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

            HStack(spacing: 8) {
                TextField(context.live ? "Ask about the meeting so far…" : "Ask about this meeting…", text: $input)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onChange(of: focusPulse) { _, _ in focused = true }
        .onAppear { demoAskIfRequested() }
    }

    /// Screenshot hook (debug builds, isolated demo runs only): asks the
    /// question in `SEAL_DEMO_ASK` as soon as there is a transcript, so the
    /// streaming answer can be seen and measured from a session.
    private func demoAskIfRequested() {
        #if DEBUG
        guard DemoMode.isActive, thread.isEmpty, !busy,
              let question = ProcessInfo.processInfo.environment["SEAL_DEMO_ASK"],
              !question.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<60 where context.lines().isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !context.lines().isEmpty else { return }
            ask(question)
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

    // MARK: - Sending

    private var hasTranscript: Bool { !context.lines().isEmpty }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty && !busy && hasTranscript
    }

    private func send() {
        guard canSend else { return }
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        ask(question)
    }

    private func ask(_ question: String) {
        let id = context.meetingID
        guard !busy, hasTranscript else { return }
        store.threads[id, default: []].append(AskMessage(role: .user, text: question))
        store.threads[id, default: []].append(AskMessage(role: .assistant, text: "", streaming: true))
        store.busy.insert(id)
        let lines = context.lines()
        let text = context.transcriptText()
        let participants = context.participants()
        let hint = context.languageHint
        let backend = context.backend
        let store = store
        Task {
            do {
                let stream = try await generator.ask(question: question, meetingID: id, lines: lines,
                                                     transcriptText: text, participants: participants,
                                                     languageHint: hint, backend: backend)
                for try await chunk in stream {
                    await MainActor.run { Self.append(chunk, to: id, in: store) }
                }
                await MainActor.run { Self.finish(id, in: store, error: nil) }
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
/// until its first words land.
private struct AskBubble: View {
    let message: AskMessage

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }
            Group {
                if message.streaming && message.text.isEmpty {
                    ProgressLabel(text: "Thinking…")
                } else {
                    Text(message.text)
                        .font(Theme.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
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
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}
