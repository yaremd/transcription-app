import SwiftUI
import AppKit

/// The live recording workspace, notes-first: the notes are the full-width
/// hero (the app is a notepad — transcription happens quietly), and the live
/// transcript is a fixed-width side panel whose visibility is a remembered
/// preference. Every session control lives in one floating control bar
/// docked bottom-center, so Stop never moves no matter which panes are open.
/// Note time labels jump the transcript to that moment, opening the panel
/// if needed.
struct RecordingView: View {
    @ObservedObject var monitor: AudioMonitor
    @State private var showDiscardConfirm = false
    /// The transcript panel's visibility — a preference, not per-session
    /// state, so the choice survives new recordings and relaunches.
    @AppStorage("liveTranscriptVisible") private var transcriptVisible = true
    @State private var jumpDate: Date?
    @State private var jumpPulse = 0

    private static let panelSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)

    var body: some View {
        splitArea
            .padding([.top, .horizontal], 16)
            .safeAreaInset(edge: .bottom, spacing: 10) {
                VStack(spacing: 6) {
                    if let error = monitor.errorMessage {
                        Text(error)
                            .font(Theme.sub)
                            .foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice = monitor.noticeMessage {
                        Text(notice)
                            .font(Theme.meta)
                            .foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Model-download status moved to the app-wide first-run
                    // banner (RootView) so it shows across panes, with progress.
                    RecordingControlBar(monitor: monitor,
                                        transcriptVisible: transcriptVisible,
                                        toggleTranscript: { withAnimation(Self.panelSpring) { transcriptVisible.toggle() } },
                                        requestDiscard: { showDiscardConfirm = true })
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(minWidth: 640, minHeight: 480)
            .confirmationDialog("Discard this recording?",
                                isPresented: $showDiscardConfirm,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { monitor.discard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The transcript and notes for this session will be deleted.")
            }
    }

    private var splitArea: some View {
        HStack(alignment: .top, spacing: 12) {
            NotesPane(monitor: monitor, onJump: jumpToMoment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if transcriptVisible {
                TranscriptPane(monitor: monitor,
                               jumpDate: jumpDate,
                               jumpPulse: jumpPulse,
                               close: { withAnimation(Self.panelSpring) { transcriptVisible = false } })
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    /// A note's time label was clicked: make sure the transcript is visible,
    /// then ask it to scroll to that moment. The pulse is deferred one turn
    /// of the run loop so a panel that was just inserted actually observes
    /// the change — it would otherwise mount already holding the new value
    /// and never scroll.
    private func jumpToMoment(_ date: Date) {
        withAnimation(Self.panelSpring) { transcriptVisible = true }
        jumpDate = date
        Task { @MainActor in jumpPulse += 1 }
    }
}

// MARK: - Notes pane (left)

/// Timestamped note blocks + a draft field — the full-width hero of the
/// screen, styled as a page rather than a widget: no well, generous margins,
/// a readable column, and the cursor already waiting in the draft field when
/// recording starts. Return commits the draft as a block stamped with the
/// current moment; committed blocks stay editable in place, and their time
/// labels jump the transcript to what was being said.
private struct NotesPane: View {
    @ObservedObject var monitor: AudioMonitor
    let onJump: (Date) -> Void
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Notes")
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach($monitor.noteBlocks) { $block in
                            NoteBlockRow(block: $block,
                                         onJump: onJump,
                                         onDelete: { monitor.deleteNoteBlock(block.id) })
                                .id(block.id)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            TextField("Add a note — Return saves it", text: $draft, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .focused($draftFocused)
                                .onSubmit {
                                    monitor.addNoteBlock(draft)
                                    draft = ""
                                    draftFocused = true
                                    if let last = monitor.noteBlocks.last {
                                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                    }
                                }
                                .help("Times link to the talk — click a note's time to see that moment")
                        }
                        .id("draft")
                    }
                    // A readable column, not wall-to-wall lines.
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // The cursor should be waiting for the user, not the other way round.
        .onChange(of: monitor.isRunning) { _, running in
            if running { draftFocused = true }
        }
        .onAppear {
            guard monitor.isRunning else { return }
            Task { @MainActor in draftFocused = true }
        }
    }
}

private struct NoteBlockRow: View {
    @Binding var block: NoteBlock
    let onJump: (Date) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(Self.timeFormatter.string(from: block.at)) {
                onJump(block.at)
            }
            .buttonStyle(.plain)
            .font(Theme.meta)
            .monospacedDigit()
            .foregroundStyle(hovering ? Theme.accent : Theme.accent.opacity(0.65))
            .help("Show what was being said at this moment")

            TextField("", text: $block.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete note", role: .destructive, action: onDelete)
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Transcript pane (right)

/// The live transcript as a fixed-width side panel: speaker-labeled
/// paragraphs, a slim header (just copy + close), and — before any words
/// arrive — a guided listening state that shows both audio sources being
/// heard. All session controls live in the floating control bar, not here.
private struct TranscriptPane: View {
    @ObservedObject var monitor: AudioMonitor
    let jumpDate: Date?
    let jumpPulse: Int
    let close: () -> Void

    @State private var highlighted: Set<UUID> = []
    @State private var suspendAutoScroll = false
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionLabel("Transcript")
                if monitor.isRunning && !monitor.isPaused {
                    PulsingDot(color: Theme.red)
                }
                Spacer()

                Button {
                    let text = monitor.transcript
                        .map { "\($0.speaker): \($0.text)" }
                        .joined(separator: "\n")
                    copyToPasteboard(text)
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
                .disabled(monitor.transcript.isEmpty)
                .help("Copy the transcript so far")

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide the transcript")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            ThemeDivider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if monitor.transcript.isEmpty && monitor.liveLines.isEmpty {
                            if monitor.isRunning {
                                GuidedListeningEmptyState(levels: monitor.levels)
                                    .padding(.top, 12)
                            } else {
                                Text("The conversation will appear here.")
                                    .font(Theme.sub)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 24)
                            }
                        }
                        ForEach(Array(monitor.transcript.enumerated()), id: \.element.id) { index, line in
                            TranscriptRow(speaker: line.speaker,
                                          text: line.text,
                                          showSpeaker: index == 0 || monitor.transcript[index - 1].speaker != line.speaker,
                                          highlighted: highlighted.contains(line.id))
                                .id(line.id)
                        }
                        ForEach(liveSpeakers, id: \.self) { speaker in
                            TranscriptRow(speaker: speaker,
                                          text: monitor.liveLines[speaker] ?? "",
                                          live: true)
                                .id("live-\(speaker)")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: transcriptGrowth) { _, _ in
                    guard !suspendAutoScroll else { return }
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: monitor.liveLines) { _, _ in
                    guard !suspendAutoScroll else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: jumpPulse) { _, _ in
                    jump(proxy)
                }
            }
        }
        .insetPanel()
    }

    private var liveSpeakers: [String] {
        monitor.liveLines.keys.sorted { first, _ in first == "You" }
    }

    /// Changes whenever the transcript gains content. Line count alone is not
    /// enough: an utterance continuing the current turn is merged into the last
    /// line, growing it without adding one, and auto-scroll would stall for the
    /// length of a long turn.
    private var transcriptGrowth: Int {
        monitor.transcript.count &+ (monitor.transcript.last?.text.count ?? 0)
    }

    /// Scrolls to the lines spoken around `jumpDate` and highlights them.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let jumpDate, !monitor.transcript.isEmpty else { return }
        let lines = monitor.transcript
        let target = lines.last(where: { $0.at <= jumpDate }) ?? lines[0]
        let near = lines.filter { abs($0.at.timeIntervalSince(target.at)) < 6 }.map(\.id)
        highlighted = Set(near)
        suspendAutoScroll = true
        withAnimation { proxy.scrollTo(target.id, anchor: .center) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { highlighted = [] }
            suspendAutoScroll = false
        }
    }
}

/// What the transcript panel shows while listening but before any words
/// arrive: both audio sources with live level meters, so "is it hearing me?"
/// is answered at a glance — and the You/Others model is taught exactly when
/// it matters. Levels are held (not observed) and sampled via onReceive so
/// their ~30 Hz updates redraw only these two small meters.
private struct GuidedListeningEmptyState: View {
    let levels: AudioLevels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mic: CGFloat = 0
    @State private var system: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            meterRow(label: "You · microphone", tint: Theme.accent, level: mic)
            meterRow(label: "Others · call audio", tint: Theme.green, level: system)
            Text("Both sides are transcribed on your Mac — speak, or start your call.")
                .font(Theme.meta)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(levels.$mic) { value in
            mic = CGFloat(min(1, max(0, value)))
            system = CGFloat(min(1, max(0, levels.system)))
        }
    }

    private func meterRow(label: String, tint: Color, level: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(tint)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(5, geo.size.width * level))
                        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 5)
        }
    }
}

/// The elapsed recording time, ticking once a second next to the red dot —
/// quiet, constant reassurance that capture is really happening. Wrapped in a
/// TimelineView so only these few digits redraw each second, never the growing
/// transcript beside them. Wall-clock from the session's start, so it matches
/// the duration the finished meeting is saved with.
struct RecordingTimerLabel: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(start)))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Shared rows (also used by the saved-meeting view)

/// One line of transcript in the speaker-labeled paragraph style shared by the
/// live recording view and the saved meeting. Consecutive lines from the same
/// speaker pass `showSpeaker: false`, so the label appears once per turn and a
/// run reads as one person talking rather than a stutter of repeated labels. A
/// jumped-to line lifts onto a soft accent wash.
struct TranscriptRow: View {
    let speaker: String
    let text: String
    var live: Bool = false
    var showSpeaker: Bool = true
    var highlighted: Bool = false
    /// Which side the color coding follows. Defaults to the label itself;
    /// pass explicitly when `speaker` is a real name replacing "You"/"Others".
    var isYou: Bool? = nil

    private var tint: Color { (isYou ?? (speaker == "You")) ? Theme.accent : Theme.green }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showSpeaker {
                HStack(spacing: 5) {
                    Text(speaker.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(tint)
                    if live {
                        PulsingDot(color: tint)
                    }
                }
            }
            Text(text)
                .font(Theme.body)
                .lineSpacing(2)
                .foregroundStyle(live ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(highlighted ? tint.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .animation(.easeOut(duration: 0.2), value: highlighted)
    }
}

/// Small breathing dot marking live activity. Under Reduce Motion it holds
/// steady — presence still reads, without the pulse.
struct PulsingDot: View {
    let color: Color
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(dim ? 0.25 : 0.9)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - Notes rendering (shared with the saved-meeting view)

struct NotesView: View {
    let notes: String

    var body: some View {
        let lines = notes.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("### ") {
            Text(clean(String(line.dropFirst(4))))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        } else if line.hasPrefix("## ") {
            // Section headings ("Summary", "Key points") carry the page's
            // structure — they need real size and air to read as landmarks.
            Text(clean(String(line.dropFirst(3))))
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 12)
        } else if line.hasPrefix("# ") {
            Text(clean(String(line.dropFirst(2))))
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 12)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(.tertiary)
                inlineText(String(line.dropFirst(2)))
                    .lineSpacing(2.5)
            }
            .font(Theme.body)
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 4)
        } else {
            inlineText(line)
                .font(Theme.body)
                .lineSpacing(2.5)
        }
    }

    /// Inline markdown (bold, italics) rendered properly instead of being
    /// stripped — the model uses **bold** for names and decisions, and that
    /// emphasis is worth keeping.
    private func inlineText(_ s: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(clean(s))
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
