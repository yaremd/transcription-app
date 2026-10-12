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
    /// A screen capture at this moment rather than speech.
    var frame: ScreenFrame? = nil
    var frameURL: URL? = nil

    /// Speech items with the meeting's screen captures slotted in at their
    /// moment — each before the first line spoken after it; lines without
    /// timestamps keep their order and any captures follow them.
    static func merging(_ speech: [TranscriptItem], frames: [ScreenFrame], url: (ScreenFrame) -> URL) -> [TranscriptItem] {
        guard !frames.isEmpty else { return speech }
        let frames = frames.sorted { $0.at < $1.at }
        var out: [TranscriptItem] = []
        var next = 0
        func item(_ frame: ScreenFrame) -> TranscriptItem {
            TranscriptItem(id: frame.id, speaker: frame.label, text: frame.text, at: frame.at,
                           isYou: false, voiceIndex: nil, voice: nil, live: false,
                           frame: frame, frameURL: url(frame))
        }
        for line in speech {
            if let at = line.at {
                while next < frames.count, frames[next].at <= at {
                    out.append(item(frames[next]))
                    next += 1
                }
            }
            out.append(line)
        }
        while next < frames.count {
            out.append(item(frames[next]))
            next += 1
        }
        return out
    }
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
                            Group {
                                if let frame = item.frame {
                                    ScreenFrameRow(frame: frame, url: item.frameURL,
                                                   highlighted: highlighted.contains(item.id) || tapped == item.id)
                                } else {
                                    TranscriptRow(speaker: item.speaker,
                                                  text: item.text,
                                                  live: item.live,
                                                  showSpeaker: index == 0
                                                      || items[index - 1].speaker != item.speaker
                                                      || items[index - 1].frame != nil,
                                                  highlighted: highlighted.contains(item.id) || tapped == item.id,
                                                  isYou: item.isYou,
                                                  voiceIndex: item.voiceIndex)
                                }
                            }
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
            let committed = items.filter { !$0.live && $0.frame == nil }.count
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
        if let url = item.frameURL {
            Button("Open the capture") { NSWorkspace.shared.open(url) }
            Button("Copy the text on screen") { copyToPasteboard(item.text) }
        } else {
            Button("Copy line") { copyToPasteboard("\(item.speaker): \(item.text)") }
        }
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

// MARK: - A screen capture in the transcript

/// One capture where it happened: the picture small, the text Seal read off
/// it beside it, both quiet next to the speech. Click the picture to open
/// it full size.
struct ScreenFrameRow: View {
    let frame: ScreenFrame
    let url: URL?
    var highlighted = false

    @State private var thumbnail: NSImage?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 9, weight: .semibold))
                Text(frame.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(Theme.inset)
                    }
                }
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
                .help("Open the capture")

                if frame.text.isEmpty {
                    Text("Nothing readable was on screen.")
                        .font(Theme.sub)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(frame.text)
                        .font(Theme.sub)
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 4)
                        .textSelection(.enabled)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(highlighted ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            guard let url else { return }
            let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            thumbnail = loaded
        }
    }
}
