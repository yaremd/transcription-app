import SwiftUI

/// One line of transcript as the panel draws it — from the live session or a
/// saved meeting, which no longer need two different panels.
struct TranscriptItem: Identifiable, Equatable {
    let id: UUID
    let speaker: String
    let text: String
    let at: Date?
    let isYou: Bool
    let voiceIndex: Int?
    /// The identified far-side voice ("S2") this line belongs to, if any —
    /// what a rename is keyed by.
    let voice: String?
    /// Still being spoken: shown dimmed, after the committed lines.
    let live: Bool
}

/// The transcript as a companion column: speaker-labeled paragraphs, a slim
/// header (line count, copy, the transcript's own actions), and — while a
/// recording waits for its first words — the guided listening state showing
/// both audio sources being heard.
struct TranscriptPanel<Banner: View, Actions: View>: View {
    let items: [TranscriptItem]
    /// A live session: a pulsing dot in the header, the listening state
    /// before any words, and auto-scroll as lines arrive.
    let recording: Bool
    var paused = false
    var levels: AudioLevels? = nil
    var systemAudioOn = true
    /// A moment to scroll to and highlight; `jumpPulse` is bumped so the same
    /// moment can be asked for twice.
    var jumpDate: Date? = nil
    var jumpPulse = 0
    /// For lines saved before timestamps existed: spread them evenly across
    /// the meeting so jumps and anchors still land approximately.
    var fallbackStart: Date? = nil
    var fallbackDuration: TimeInterval = 0
    let copyText: () -> String
    var showActions = true
    /// Tapping a line (saved meetings): attach the next jotted note to it.
    var onAnchor: ((Date) -> Void)? = nil
    /// A line's context-menu rename of its identified voice.
    var onRenameVoice: ((TranscriptItem) -> Void)? = nil
    /// Above the lines: a speaker suggestion, a running job, an error.
    @ViewBuilder let banner: () -> Banner
    /// The ⋯ menu's items: identify speakers, improve transcript.
    @ViewBuilder let actions: () -> Actions

    @State private var highlighted: Set<UUID> = []
    @State private var tapped: UUID?
    @State private var suspendAutoScroll = false
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            banner()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if items.isEmpty { emptyState }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            TranscriptRow(speaker: item.speaker,
                                          text: item.text,
                                          live: item.live,
                                          showSpeaker: index == 0 || items[index - 1].speaker != item.speaker,
                                          highlighted: highlighted.contains(item.id) || tapped == item.id,
                                          isYou: item.isYou,
                                          voiceIndex: item.voiceIndex)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { anchor(index) }
                                .contextMenu { contextMenu(item) }
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .padding(12)
                }
                .onChange(of: growth) { _, _ in
                    guard recording, !suspendAutoScroll else { return }
                    withAnimation { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
                }
                .onChange(of: jumpPulse) { _, _ in jump(proxy) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if recording {
                if paused {
                    Text("Paused").font(Theme.metaMedium).foregroundStyle(.secondary)
                } else {
                    PulsingDot(color: Theme.red)
                }
            }
            let committed = items.filter { !$0.live }.count
            if committed > 0 {
                Text("\(committed) lines")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                copyToPasteboard(copyText())
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
            .disabled(items.isEmpty)
            .help(recording ? "Copy the transcript so far" : "Copy the transcript")

            if showActions {
                Menu { actions() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Transcript actions")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var emptyState: some View {
        if recording, let levels {
            GuidedListeningEmptyState(levels: levels, systemAudioOn: systemAudioOn)
                .padding(.top, 12)
        } else {
            Text(recording ? "The conversation will appear here." : "No transcript.")
                .font(Theme.sub)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
        }
    }

    @ViewBuilder
    private func contextMenu(_ item: TranscriptItem) -> some View {
        if item.voice != nil, let onRenameVoice {
            Button("Name \(item.speaker)…") { onRenameVoice(item) }
        }
        Button("Copy line") { copyToPasteboard("\(item.speaker): \(item.text)") }
    }

    /// Changes whenever the transcript gains content. Line count alone is not
    /// enough: an utterance continuing the current turn is merged into the
    /// last line, growing it without adding one, and auto-scroll would stall
    /// for the length of a long turn.
    private var growth: Int {
        items.count &+ (items.last?.text.count ?? 0)
    }

    /// A line's time: its real one, or — for meetings saved before timestamps
    /// were kept — an even estimate spread across the duration.
    private func effectiveTime(_ index: Int) -> Date? {
        if let at = items[index].at { return at }
        guard let fallbackStart else { return nil }
        guard items.count > 1, fallbackDuration > 0 else { return fallbackStart }
        let frac = Double(index) / Double(items.count - 1)
        return fallbackStart.addingTimeInterval(fallbackDuration * frac)
    }

    /// Tapping a line anchors the next note to it and flashes it briefly so
    /// the choice is visible.
    private func anchor(_ index: Int) {
        guard let onAnchor, let at = effectiveTime(index) else { return }
        onAnchor(at)
        let id = items[index].id
        tapped = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if tapped == id { tapped = nil }
        }
    }

    /// Scrolls to the line at (or just before) the asked-for moment and
    /// highlights everything within ~6 s of it, then fades.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let jumpDate, !items.isEmpty else { return }
        var targetIndex = 0
        for i in items.indices {
            if let t = effectiveTime(i), t <= jumpDate { targetIndex = i }
        }
        guard let targetAt = effectiveTime(targetIndex) else { return }
        highlighted = Set(items.indices
            .filter { i in
                guard let t = effectiveTime(i) else { return false }
                return abs(t.timeIntervalSince(targetAt)) < 6
            }
            .map { items[$0].id })
        suspendAutoScroll = true
        withAnimation { proxy.scrollTo(items[targetIndex].id, anchor: .center) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { highlighted = [] }
            suspendAutoScroll = false
        }
    }
}
