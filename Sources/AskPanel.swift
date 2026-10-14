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
    private var drafts: [UUID: AskDraft] = [:]

    /// The question being written for a meeting, wherever its box is showing.
    func draft(for meetingID: UUID) -> AskDraft {
        if let draft = drafts[meetingID] { return draft }
        let draft = AskDraft()
        drafts[meetingID] = draft
        return draft
    }
}

/// A question being written, and the files going with it. It belongs to the
/// meeting, not to a box: the Ask box sits under the notes until the Ask tab
/// opens and then at the foot of the conversation, and a half-typed question
/// and its files move with it.
final class AskDraft: ObservableObject {
    @Published var text = ""
    @Published var attachments: [AskAttachment] = []
    /// Set when a question was just sent from one box and the conversation
    /// opened: the box beside the answer takes the cursor for the follow-up.
    @Published var focusRequested = false
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

/// The Ask half of the companion: the conversation with this meeting,
/// answered from its transcript on the Mac, during the meeting as well as
/// after, with the Ask box at its foot, right under the answer it follows.
struct AskPanel: View {
    let context: AskContext
    /// The page's Ask box, which moves here while this tab is open.
    let composer: AnyView

    @EnvironmentObject private var entitlements: EntitlementService
    @ObservedObject private var store = AskStore.shared

    private var thread: [AskMessage] { store.threads[context.meetingID] ?? [] }
    private var busy: Bool { store.busy.contains(context.meetingID) }
    private var hasTranscript: Bool { !context.lines().isEmpty }

    var body: some View {
        if entitlements.allows(.askMeeting) {
            VStack(spacing: 0) {
                conversation
                composer
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        } else {
            locked
        }
    }

    @ViewBuilder
    private var conversation: some View {
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
                .onAppear { proxy.scrollTo("ask-bottom", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Before the first question: what Ask does, where to type, and a few
    /// questions worth one click so nobody stares at an empty panel.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(context.live
                 ? "Answered from the transcript so far, on your Mac. Ask while it's still happening."
                 : "Answered only from this meeting's transcript, on your Mac.")
                .font(Theme.sub)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(AskSession.starters(live: context.live), id: \.self) { question in
                    Button { AskSession.ask(question, context: context) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "text.bubble")
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
                Text("Or type your own below (⌘J). Drop a file on the box, a plan, a slide, a photo of the whiteboard, and the answer sees it too.")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
}

/// One bubble: the user's on the right on an accent wash, the model's on the
/// left on a surface. A reply still being written shows a quiet spinner
/// until its first words land. The files that went with a question are
/// listed under it by name.
private struct AskBubble: View {
    let message: AskMessage

    /// The model answers in Markdown; its **bold** and *italics* render as
    /// such instead of as asterisks. Line breaks stay where it put them, and
    /// text that isn't valid Markdown yet (mid-stream) shows as written.
    static func styled(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                if message.streaming && message.text.isEmpty {
                    ProgressLabel(text: "Thinking…")
                } else {
                    Text(Self.styled(message.text))
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
