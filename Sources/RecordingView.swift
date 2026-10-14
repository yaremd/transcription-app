import SwiftUI
import AppKit

/// The live meeting, on the same page it will be read on afterwards: the
/// notes document on the left — a title, and the notes you type, each stamped
/// with the moment — and the companion beside it, the transcript arriving
/// line by line or Ask, which answers from everything said so far. Every
/// session control lives in one floating bar docked under the document,
/// paired with the Ask bar, so Stop never moves no matter what else is open.
struct RecordingView: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: MeetingStore
    /// The companion's visibility and tab — preferences shared with the saved
    /// page, so the choice survives Stop, new recordings, and relaunches.
    @AppStorage(CompanionPrefs.visibleKey) private var companionVisible = true
    @AppStorage(CompanionPrefs.tabKey) private var companionTabRaw = CompanionTab.transcript.rawValue

    @State private var showDiscardConfirm = false
    @State private var jumpDate: Date?
    @State private var jumpPulse = 0
    @State private var jotFocusPulse = 0
    /// The whole page's width, for the companion's toolbar tabs.
    @State private var pageWidth: CGFloat = 1000

    private var companionTab: Binding<CompanionTab> {
        Binding(get: { CompanionTab(rawValue: companionTabRaw) ?? .transcript },
                set: { companionTabRaw = $0.rawValue })
    }

    var body: some View {
        MeetingPageLayout(companionVisible: companionVisible) {
            DocumentColumn { document }
                .safeAreaInset(edge: .bottom, spacing: 10) { controls }
        } companion: {
            CompanionPanel(tab: companionTab.wrappedValue) {
                TranscriptPanel(items: liveItems,
                                recording: monitor.isRunning,
                                paused: monitor.isPaused,
                                levels: monitor.levels,
                                systemAudioOn: monitor.systemAudioOn,
                                jumpDate: jumpDate,
                                jumpPulse: jumpPulse,
                                copyText: { monitor.transcript.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n") },
                                showActions: false,
                                banner: { EmptyView() },
                                actions: { EmptyView() })
            } ask: {
                AskPanel(context: askContext, composer: AnyView(liveBox(inPanel: true)))
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .trackingWidth($pageWidth)
        .meetingPageToolbar(
            share: nil,
            companion: CompanionToolbar(visible: companionVisible, tab: companionTab,
                                        width: MeetingPageLayout<EmptyView, EmptyView>.companionWidth(for: pageWidth),
                                        close: { withAnimation(MeetingPageLayout<EmptyView, EmptyView>.spring) { companionVisible = false } }))
        .confirmationDialog("Discard this recording?",
                            isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { monitor.discard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript and notes for this session will be deleted.")
        }
        // The cursor should be waiting for the user, not the other way round.
        .onChange(of: monitor.isRunning) { _, running in
            if running { jotFocusPulse += 1 }
        }
        .onAppear {
            if monitor.isRunning { Task { @MainActor in jotFocusPulse += 1 } }
        }
    }

    // MARK: - Document

    private var document: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Untitled meeting", text: $monitor.liveTitle)
                .font(Theme.docTitle)
                .textFieldStyle(.plain)
            HStack(spacing: 6) {
                if monitor.isRunning {
                    if monitor.isPaused {
                        Text("Paused")
                    } else {
                        PulsingDot(color: Theme.red)
                        Text("Recording")
                    }
                    Text("·")
                }
                Text((monitor.recordingStart ?? Date()).formatted(date: .abbreviated, time: .shortened))
                if monitor.language != .auto {
                    Text("·")
                    Text(monitor.language.label)
                }
            }
            .font(Theme.sub)
            .foregroundStyle(.secondary)
            .padding(.top, 6)

            JotList(blocks: $monitor.noteBlocks,
                    onJump: jumpToMoment,
                    onAdd: { monitor.addNoteBlock($0) },
                    onDelete: { monitor.deleteNoteBlock($0) },
                    placeholder: "Type a note — Return saves it with the time",
                    focusPulse: jotFocusPulse)
                .padding(.top, 24)

            if monitor.noteBlocks.isEmpty {
                Text("Anything you type here is stamped with the moment it was said. When you stop, Seal writes the full notes from the transcript and your notes together.")
                    .font(Theme.sub)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
    }

    /// The floating control bar, with any error or notice just above it.
    private var controls: some View {
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
            if askOpen {
                // The Ask box is under the answers; the session keeps its chip.
                RecordingChip(monitor: monitor, requestDiscard: { showDiscardConfirm = true })
                    .padding(7)
                    .floatingGlass(in: Capsule())
            } else {
                liveBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var askOpen: Bool { companionVisible && companionTab.wrappedValue == .ask }

    /// The one bar under the live page: the recording chip (pause, stop and
    /// the rest are a click on it), the transcript button, and the box that
    /// asks what's been said. The same bar as a saved meeting's, plus the chip.
    private var liveBar: some View {
        liveBox(inPanel: false)
            .frame(maxWidth: 560)
    }

    /// The Ask box, under the notes (with the recording chip first) or at the
    /// foot of the Ask tab: one draft, whichever is showing.
    private func liveBox(inPanel: Bool) -> AskBar {
        AskBar(context: askContext,
               hasTranscript: !monitor.transcript.isEmpty,
               transcriptOpen: companionVisible && companionTab.wrappedValue == .transcript,
               toggleTranscript: toggleTranscript,
               actions: liveActions,
               showAnswers: showAnswers,
               draft: AskStore.shared.draft(for: monitor.currentMeetingID),
               leading: inPanel ? nil : AnyView(RecordingChip(monitor: monitor, requestDiscard: { showDiscardConfirm = true })),
               showsTranscriptButton: !inPanel,
               takesFocusRequests: inPanel)
    }

    /// What the bar's "/" can do while recording. Stop, star and snap keep
    /// their menu shortcuts, so they are shown here, not registered twice.
    private var liveActions: [AskBarAction] {
        let transcriptShowing = companionVisible && companionTab.wrappedValue == .transcript
        return [
            AskBarAction(id: "pause", title: monitor.isPaused ? "Resume the recording" : "Pause the recording",
                         symbol: monitor.isPaused ? "play" : "pause", group: .session,
                         enabled: monitor.isRunning,
                         perform: { monitor.pauseResume() }),
            AskBarAction(id: "stop", title: "Stop and save", symbol: "stop", group: .session,
                         enabled: monitor.isRunning, hint: "⇧⌘R",
                         perform: { monitor.toggle() }),
            AskBarAction(id: "star", title: "Star this moment", symbol: "star", group: .session,
                         enabled: monitor.isRunning, featured: true, hint: "⇧⌘H",
                         perform: { monitor.addHighlight() }),
            AskBarAction(id: "snap", title: "Snap the screen", symbol: "camera.viewfinder", group: .session,
                         enabled: monitor.isRunning, featured: true, hint: "⇧⌘S",
                         perform: { monitor.snapScreen() }),
            AskBarAction(id: "transcript", title: transcriptShowing ? "Hide the transcript" : "Show the transcript",
                         symbol: "waveform", group: .transcript, hint: "⇧⌘T",
                         perform: toggleTranscript),
        ]
    }

    /// A question went from the bar: its answer streams in the companion, and
    /// the box moves there with the cursor, ready for the follow-up.
    private func showAnswers() {
        guard !askOpen else { return }
        AskStore.shared.draft(for: monitor.currentMeetingID).focusRequested = true
        withAnimation(MeetingPageLayout<EmptyView, EmptyView>.spring) {
            companionTab.wrappedValue = .ask
            companionVisible = true
        }
    }

    private func toggleTranscript() { toggleCompanion(.transcript) }

    /// Opens the companion on `target`, or closes it when that tab is already
    /// showing.
    private func toggleCompanion(_ target: CompanionTab) {
        withAnimation(MeetingPageLayout<EmptyView, EmptyView>.spring) {
            if companionVisible && companionTab.wrappedValue == target {
                companionVisible = false
            } else {
                companionTab.wrappedValue = target
                companionVisible = true
            }
        }
    }

    /// A note's time label was clicked: make sure the transcript is showing,
    /// then ask it to scroll to that moment. The pulse is deferred one turn
    /// of the run loop so a panel that was just inserted actually observes
    /// the change — it would otherwise mount already holding the new value
    /// and never scroll.
    private func jumpToMoment(_ date: Date) {
        withAnimation(MeetingPageLayout<EmptyView, EmptyView>.spring) {
            companionTab.wrappedValue = .transcript
            companionVisible = true
        }
        jumpDate = date
        Task { @MainActor in jumpPulse += 1 }
    }

    // MARK: - Companion content

    /// Stable ids for the two in-progress lines, so the rows aren't rebuilt
    /// on every partial result.
    private static let liveIDs: [String: UUID] = ["You": UUID(), "Others": UUID()]

    private var liveItems: [TranscriptItem] {
        var items = monitor.transcript.map {
            TranscriptItem(id: $0.id, speaker: $0.speaker, text: $0.text, at: $0.at,
                           isYou: $0.speaker == "You", voiceIndex: nil, voice: nil, live: false)
        }
        let meetingID = monitor.currentMeetingID
        items = TranscriptItem.merging(items, frames: monitor.frames,
                                       url: { store.frameURL(for: meetingID, fileName: $0.fileName) })
        for speaker in monitor.liveLines.keys.sorted(by: { first, _ in first == "You" }) {
            guard let text = monitor.liveLines[speaker], !text.isEmpty else { continue }
            items.append(TranscriptItem(id: Self.liveIDs[speaker] ?? UUID(), speaker: speaker, text: text,
                                        at: nil, isYou: speaker == "You", voiceIndex: nil, voice: nil, live: true))
        }
        return items
    }

    private var askContext: AskContext {
        let monitor = monitor
        let userName = settings.userName
        let backend: NotesBackend = settings.usingCloudNotes
            ? .cloudOpenAICompatible(baseURL: settings.cloudBaseURL, apiKey: settings.cloudAPIKey, model: settings.cloudModel)
            : .localEmbedded(model: settings.embeddedModelID)
        return AskContext(
            meetingID: monitor.currentMeetingID,
            live: true,
            languageHint: monitor.language.notesHint,
            backend: backend,
            lines: {
                let start = monitor.recordingStart ?? monitor.transcript.first?.at ?? Date()
                var lines = monitor.transcript.map {
                    AskTranscriptFeed.Line(id: $0.id,
                                           label: "\(AskTranscriptFeed.stamp($0.at.timeIntervalSince(start))) \($0.speaker)",
                                           text: $0.text)
                }
                for frame in monitor.frames {
                    lines.append(AskTranscriptFeed.Line(
                        id: frame.id,
                        label: "\(AskTranscriptFeed.stamp(frame.at.timeIntervalSince(start))) \(frame.label)",
                        text: frame.transcriptLine))
                }
                return lines
            },
            transcriptText: {
                Meeting.interleaved(speech: monitor.transcript.map { (at: $0.at, text: "\($0.speaker): \($0.text)") },
                                    frames: monitor.frames).joined(separator: "\n")
            },
            participants: {
                let name = userName.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : "PARTICIPANTS: You = \(name)"
            })
    }
}

// MARK: - A jotted note

/// One editable timestamped note — the live page and the saved page share
/// it. A note carries its formatting in its own text ("- ", "[ ]", "★" — see
/// NoteMark): bullets get a dot, checkboxes a real toggle that strikes the
/// text, starred moments an amber star. The marker stays in the stored text,
/// so plain-text exports and older versions read naturally.
struct EditableNoteRow: View {
    @Binding var block: NoteBlock
    let onJump: (Date) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(Self.timeFormatter.string(from: block.at)) {
                onJump(block.at)
            }
            .buttonStyle(.plain)
            .font(Theme.meta)
            .monospacedDigit()
            .foregroundStyle(hovering ? Theme.accent : Theme.accent.opacity(0.65))
            .help("Show what was being said at this moment")

            switch NoteMark.parse(block.text) {
            case .task(let done, let body):
                Toggle("", isOn: taskDoneBinding(body: body))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                TextField("", text: taskBodyBinding(done: done), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.docBody)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            case .bullet:
                Text("•")
                    .font(Theme.docBody)
                    .foregroundStyle(.tertiary)
                TextField("", text: bulletBodyBinding(), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.docBody)
            case .highlight:
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.amber)
                TextField("Starred — add why it matters (optional)",
                          text: highlightBodyBinding(), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.docBody)
            case .plain:
                TextField("", text: $block.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.docBody)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete note", role: .destructive, action: onDelete)
        }
    }

    // The body is edited while the marker stays put — each binding rewrites
    // the stored text with the marker re-attached.

    private func taskDoneBinding(body: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .task(let done, _) = NoteMark.parse(block.text) { return done }
                return false
            },
            set: { block.text = NoteMark.composeTask(done: $0, body: body) })
    }

    private func taskBodyBinding(done: Bool) -> Binding<String> {
        Binding(
            get: {
                if case .task(_, let body) = NoteMark.parse(block.text) { return body }
                return block.text
            },
            set: { block.text = NoteMark.composeTask(done: done, body: $0) })
    }

    private func bulletBodyBinding() -> Binding<String> {
        Binding(
            get: {
                if case .bullet(let body) = NoteMark.parse(block.text) { return body }
                return block.text
            },
            set: { block.text = "- " + $0 })
    }

    private func highlightBodyBinding() -> Binding<String> {
        Binding(
            get: {
                if case .highlight(let body) = NoteMark.parse(block.text) { return body }
                return block.text
            },
            set: { block.text = $0.isEmpty ? "★" : "★ " + $0 })
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Listening state

/// What the transcript panel shows while listening but before any words
/// arrive: both audio sources with live level meters, so "is it hearing me?"
/// is answered at a glance — and the You/Others model is taught exactly when
/// it matters. Levels are held (not observed) and sampled via onReceive so
/// their ~30 Hz updates redraw only these two small meters.
struct GuidedListeningEmptyState: View {
    let levels: AudioLevels
    var systemAudioOn = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mic: CGFloat = 0
    @State private var system: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Ears up, waiting for the first word — it leaves with this state,
            // the moment there's a transcript to read instead.
            ListeningSeal(width: 116)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 2)
            meterRow(label: "You · microphone", tint: Theme.accent, level: mic)
            if systemAudioOn {
                meterRow(label: "Others · call audio", tint: Theme.green, level: system)
            }
            Text(systemAudioOn
                 ? "Both sides are transcribed on your Mac — speak, or start your call."
                 : "Call audio is off (Settings → Recording) — only your microphone is transcribed.")
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
                .lineLimit(1)
                .fixedSize()
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

// MARK: - Shared rows

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
    /// Which far-side voice this line belongs to, as a position in the
    /// meeting's ordered voices. Nil — the live view, and any transcript that
    /// was never diarized — means the single unnamed "Others", which keeps
    /// index 0 and therefore the colour it has always had.
    var voiceIndex: Int? = nil

    private var tint: Color {
        (isYou ?? (speaker == "You"))
            ? Theme.accent
            : Theme.speakerColor(voiceIndex: voiceIndex ?? 0)
    }

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

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
