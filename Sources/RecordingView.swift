import SwiftUI
import AppKit

/// The live recording workspace, pared down to the two things that matter:
/// timestamped notes on the left, the live transcript as a chat on the right
/// ("You" bubbles right-aligned and accent-tinted, "Others" left, neutral).
/// Everything else steps back: recording actions sit in the transcript
/// panel's header, language/speed live in a small popover there, rare and
/// destructive actions hide behind an ellipsis, and a single slim status
/// line with the privacy badge closes the screen. The transcript collapses
/// to a pill so notes get the full width; every new recording starts
/// expanded. Note time labels jump the transcript to that moment.
struct RecordingView: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var settings: AppSettings
    @State private var showDiscardConfirm = false
    @State private var transcriptExpanded = true
    @State private var jumpDate: Date?
    @State private var jumpPulse = 0

    private static let panelSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            splitArea
            if let error = monitor.errorMessage {
                Text(error)
                    .font(Theme.sub)
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusFooter
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
        .confirmationDialog("Discard this recording?",
                            isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { monitor.discard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript and notes for this session will be deleted.")
        }
        .onChange(of: monitor.isRunning) { _, running in
            // Every new recording starts with the transcript expanded.
            if running { withAnimation(Self.panelSpring) { transcriptExpanded = true } }
        }
    }

    private var splitArea: some View {
        HStack(alignment: .top, spacing: 12) {
            NotesPane(monitor: monitor, onJump: jumpToMoment)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if transcriptExpanded {
                TranscriptPane(monitor: monitor,
                               jumpDate: jumpDate,
                               jumpPulse: jumpPulse,
                               startStopStyle: startStopStyle,
                               requestDiscard: { showDiscardConfirm = true },
                               collapse: { withAnimation(Self.panelSpring) { transcriptExpanded = false } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if !transcriptExpanded {
                CollapsedTranscriptPill(monitor: monitor,
                                        startStopStyle: startStopStyle,
                                        expand: { withAnimation(Self.panelSpring) { transcriptExpanded = true } })
                    .padding(10)
            }
        }
    }

    /// A note's time label was clicked: make sure the transcript is visible,
    /// then ask it to scroll to that moment.
    private func jumpToMoment(_ date: Date) {
        withAnimation(Self.panelSpring) { transcriptExpanded = true }
        jumpDate = date
        jumpPulse += 1
    }

    private var statusFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(monitor.modelStatus.isEmpty ? monitor.statusMessage : "\(monitor.statusMessage)  ·  \(monitor.modelStatus)")
                .font(Theme.meta)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            Spacer()
            PrivacyBadge(usingCloud: settings.usingCloudNotes)
        }
    }

    /// One filled button at a time: red Stop while recording, indigo Start
    /// otherwise.
    private var startStopStyle: LinearButtonStyle {
        if monitor.isRunning { return LinearButtonStyle(kind: .primary, tint: Theme.red, compact: true) }
        if monitor.transcript.isEmpty { return LinearButtonStyle(kind: .primary, compact: true) }
        return LinearButtonStyle(kind: .quiet, compact: true)
    }
}

// MARK: - Notes pane (left)

/// Timestamped note blocks + a draft field. Return commits the draft as a
/// block stamped with the current moment; committed blocks stay editable in
/// place, and their time labels jump the transcript to what was being said.
private struct NotesPane: View {
    @ObservedObject var monitor: AudioMonitor
    let onJump: (Date) -> Void
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Notes")
                Spacer()
                Text("Return adds a note · times link to the talk")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ThemeDivider()

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
                            TextField("Add a note…", text: $draft, axis: .vertical)
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
                        }
                        .id("draft")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .insetPanel()
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

/// Chat-style live transcript with the session's controls in its header:
/// Stop/Pause up front, language & speed one level deeper in a popover,
/// Discard behind the ellipsis, and two tiny level dots proving both sides
/// are heard.
private struct TranscriptPane: View {
    @ObservedObject var monitor: AudioMonitor
    let jumpDate: Date?
    let jumpPulse: Int
    let startStopStyle: LinearButtonStyle
    let requestDiscard: () -> Void
    let collapse: () -> Void

    @State private var highlighted: Set<UUID> = []
    @State private var suspendAutoScroll = false
    @State private var showSettings = false
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionLabel("Transcript")
                if monitor.isRunning {
                    if monitor.isPaused {
                        Text("Paused")
                            .font(Theme.metaMedium)
                            .foregroundStyle(.secondary)
                    } else {
                        PulsingDot(color: Theme.red)
                        if let start = monitor.recordingStart {
                            RecordingTimerLabel(start: start)
                        }
                    }
                }
                Spacer()

                Button(monitor.isRunning ? "Stop" : "Start Listening") {
                    monitor.toggle()
                }
                .buttonStyle(startStopStyle)
                .keyboardShortcut(.defaultAction)

                if monitor.isRunning {
                    Button(monitor.isPaused ? "Resume" : "Pause") {
                        monitor.pauseResume()
                    }
                    .buttonStyle(.linearQuietCompact)
                }

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

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Language & speed")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SessionSettingsPopover(monitor: monitor)
                }

                if monitor.isRunning {
                    Menu {
                        Button("Discard recording…", role: .destructive, action: requestDiscard)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 1, height: 14)

                Button(action: collapse) {
                    Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide the transcript")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            ThemeDivider()

            if monitor.isRunning {
                // A live, color-coded waveform — proof at a glance that audio is
                // flowing, and who's speaking (indigo = you, green = the call).
                LiveWaveform(levels: monitor.levels,
                             active: monitor.isRunning && !monitor.isPaused)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                ThemeDivider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if monitor.transcript.isEmpty && monitor.liveLines.isEmpty {
                            Text(monitor.isRunning
                                 ? "Listening… speak, and play the call for the “Others” side."
                                 : "The conversation will appear here.")
                                .font(Theme.sub)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 24)
                                .padding(.horizontal, 24)
                        }
                        ForEach(monitor.transcript) { line in
                            ChatBubble(text: line.text,
                                       isYou: line.speaker == "You",
                                       live: false,
                                       highlighted: highlighted.contains(line.id))
                                .id(line.id)
                        }
                        ForEach(liveSpeakers, id: \.self) { speaker in
                            ChatBubble(text: monitor.liveLines[speaker] ?? "",
                                       isYou: speaker == "You",
                                       live: true)
                                .id("live-\(speaker)")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: monitor.transcript.count) { _, _ in
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

/// Language & speed, one level below the surface. Language applies live to
/// the next phrases; speed needs the next meeting (it swaps the model).
private struct SessionSettingsPopover: View {
    @ObservedObject var monitor: AudioMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("Language")
                Picker("Language", selection: $monitor.language) {
                    ForEach(TranscriptLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 250)
            }
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("Speed")
                Picker("Speed", selection: $monitor.speed) {
                    ForEach(TranscriptionSpeed.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160)
                .disabled(monitor.isRunning)
                if monitor.isRunning {
                    Text("Speed applies from the next meeting.")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
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

/// A live, scrolling waveform. New bars enter on the right and scroll left,
/// each one colored by who's louder right now — indigo for you (mic), green
/// for the call (system audio) — so a glance confirms both sides are heard.
/// It samples the shared level meter on that meter's own ~30 Hz cadence and
/// keeps its history in local state, so it redraws itself without ever touching
/// the transcript. When paused it holds its last shape, dimmed.
private struct LiveWaveform: View {
    /// Held, not observed: we react to its published mic level via onReceive so
    /// only this small Canvas redraws — the parent pane never does.
    let levels: AudioLevels
    var active: Bool
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 2

    @State private var bars: [Bar] = []

    struct Bar: Equatable { var level: CGFloat; var isYou: Bool }

    var body: some View {
        Canvas { context, size in
            let step = barWidth + spacing
            let capacity = max(1, Int(size.width / step))
            let visible = Array(bars.suffix(capacity))
            let midY = size.height / 2
            for (i, bar) in visible.enumerated() {
                let x = size.width - CGFloat(visible.count - i) * step
                let h = max(2, bar.level * (size.height - 2))
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(bar.isYou ? Theme.accent : Theme.green))
            }
        }
        .opacity(active ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: active)
        .onReceive(levels.$mic) { _ in
            guard active else { return }
            let mic = CGFloat(min(1, max(0, levels.mic)))
            let sys = CGFloat(min(1, max(0, levels.system)))
            var next = bars
            next.append(Bar(level: max(mic, sys), isYou: mic >= sys))
            if next.count > 260 { next.removeFirst(next.count - 260) }
            bars = next
        }
    }
}

/// One chat bubble. The speaker is encoded by side and tint: the user right
/// and accent-washed, others left on a plain surface.
private struct ChatBubble: View {
    let text: String
    let isYou: Bool
    let live: Bool
    var highlighted = false

    var body: some View {
        HStack(spacing: 0) {
            if isYou { Spacer(minLength: 48) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if live {
                    PulsingDot(color: isYou ? Theme.accent : Theme.green)
                }
                Text(text)
                    .font(Theme.body)
                    .lineSpacing(2)
                    .foregroundStyle(live ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isYou ? Theme.accent.opacity(0.13) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(highlighted ? Theme.accent
                                              : (isYou ? Theme.accent.opacity(0.25) : Theme.border),
                                  lineWidth: highlighted ? 1.5 : 1)
            )
            if !isYou { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Collapsed pill

/// What remains when the transcript is hidden: a pulsing "Transcribing…"
/// pill with the essential actions, Granola-style.
private struct CollapsedTranscriptPill: View {
    @ObservedObject var monitor: AudioMonitor
    let startStopStyle: LinearButtonStyle
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if monitor.isRunning && !monitor.isPaused {
                PulsingDot(color: Theme.red)
            }
            Text(label)
                .font(Theme.metaMedium)
                .foregroundStyle(.secondary)
            if monitor.isRunning, !monitor.isPaused, let start = monitor.recordingStart {
                RecordingTimerLabel(start: start)
            }

            Button(monitor.isRunning ? "Stop" : "Start") {
                monitor.toggle()
            }
            .buttonStyle(startStopStyle)
            .keyboardShortcut(.defaultAction)

            if monitor.isRunning {
                Button(monitor.isPaused ? "Resume" : "Pause") {
                    monitor.pauseResume()
                }
                .buttonStyle(.linearQuietCompact)
            }

            Button(action: expand) {
                Image(systemName: "rectangle.lefthalf.inset.filled.arrow.left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show the transcript")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }

    private var label: String {
        guard monitor.isRunning else { return "Transcript hidden" }
        return monitor.isPaused ? "Paused" : "Transcribing…"
    }
}

// MARK: - Shared rows (also used by the saved-meeting view)

struct TranscriptRow: View {
    let speaker: String
    let text: String
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(speaker.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(speaker == "You" ? Theme.accent : Theme.green)
                if live {
                    PulsingDot(color: speaker == "You" ? Theme.accent : Theme.green)
                }
            }
            Text(text)
                .font(Theme.body)
                .lineSpacing(2)
                .foregroundStyle(live ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small breathing dot marking live activity.
struct PulsingDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(dim ? 0.25 : 0.9)
            .onAppear {
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
        VStack(alignment: .leading, spacing: 5) {
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
                .padding(.top, 4)
        } else if line.hasPrefix("## ") {
            Text(clean(String(line.dropFirst(3))))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 8)
        } else if line.hasPrefix("# ") {
            Text(clean(String(line.dropFirst(2))))
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 8)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.tertiary)
                Text(clean(String(line.dropFirst(2))))
            }
            .font(Theme.body)
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 3)
        } else {
            Text(clean(line))
                .font(Theme.body)
                .lineSpacing(2)
        }
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
