import SwiftUI
import AppKit

/// The live recording workspace: a 50/50 split with the user's timestamped
/// notes on the left and the live transcript as a chat on the right ("You"
/// bubbles right-aligned and accent-tinted, "Others" left-aligned, neutral).
/// Recording actions live in the transcript panel's header; the panel can
/// collapse to a small pulsing pill so notes get the full width. Each note
/// block remembers when it was written — clicking its time label jumps the
/// transcript to that moment.
struct RecordingView: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var settings: AppSettings
    @State private var showNotes = false
    @State private var showDiscardConfirm = false
    @State private var transcriptExpanded = true
    @State private var jumpDate: Date?
    @State private var jumpPulse = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controlsRow
            splitArea
            if let error = monitor.errorMessage {
                Text(error)
                    .font(Theme.sub)
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            bottomRow
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
        .sheet(isPresented: $showNotes) {
            NotesSheet(monitor: monitor)
        }
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
            if running { withAnimation(.easeOut(duration: 0.2)) { transcriptExpanded = true } }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Seal")
                    .font(Theme.title)
                Text("Live, private, on-device transcription")
                    .font(Theme.sub)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PrivacyBadge(usingCloud: settings.usingCloudNotes)
        }
    }

    private var controlsRow: some View {
        HStack(alignment: .center, spacing: 16) {
            Picker("Language", selection: $monitor.language) {
                ForEach(TranscriptLanguage.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 240)
            .disabled(monitor.isRunning)

            Picker("Speed", selection: $monitor.speed) {
                ForEach(TranscriptionSpeed.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 140)
            .disabled(monitor.isRunning)

            Spacer()

            MetersView(levels: monitor.levels)
                .frame(width: 260)
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
                               collapse: { withAnimation(.easeOut(duration: 0.2)) { transcriptExpanded = false } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if !transcriptExpanded {
                CollapsedTranscriptPill(monitor: monitor,
                                        startStopStyle: startStopStyle,
                                        expand: { withAnimation(.easeOut(duration: 0.2)) { transcriptExpanded = true } })
                    .padding(10)
            }
        }
        .frame(minHeight: 300)
    }

    /// A note's time label was clicked: make sure the transcript is visible,
    /// then ask it to scroll to that moment.
    private func jumpToMoment(_ date: Date) {
        withAnimation(.easeOut(duration: 0.2)) { transcriptExpanded = true }
        jumpDate = date
        jumpPulse += 1
    }

    private var bottomRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel("Template")
                Picker("Template", selection: $monitor.template) {
                    ForEach(NotesTemplate.all) { t in Text(t.name).tag(t) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)

                if !monitor.isRunning && !monitor.transcript.isEmpty {
                    Button("Generate Notes") {
                        monitor.generateNotes()
                        showNotes = true
                    }
                    .buttonStyle(.linearPrimary)
                }
                Spacer()
            }

            Text(monitor.modelStatus.isEmpty ? monitor.statusMessage : "\(monitor.statusMessage)  ·  \(monitor.modelStatus)")
                .font(Theme.meta)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One filled button at a time: red Stop while recording, indigo Start
    /// on a fresh session, and quiet Start once a transcript is waiting —
    /// Generate Notes is the filled action then.
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

/// Chat-style live transcript. "You" bubbles sit right, accent-tinted;
/// "Others" sit left on a neutral surface. The recording actions live in the
/// panel header, and the panel can collapse to a pill.
private struct TranscriptPane: View {
    @ObservedObject var monitor: AudioMonitor
    let jumpDate: Date?
    let jumpPulse: Int
    let startStopStyle: LinearButtonStyle
    let requestDiscard: () -> Void
    let collapse: () -> Void

    @State private var highlighted: Set<UUID> = []
    @State private var suspendAutoScroll = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionLabel("Transcript")
                if monitor.isRunning && !monitor.isPaused {
                    PulsingDot(color: Theme.red)
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

                    Button("Discard", role: .destructive, action: requestDiscard)
                        .buttonStyle(.linearDestructiveCompact)
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if monitor.transcript.isEmpty && monitor.liveLines.isEmpty {
                            Text(monitor.isRunning ? "Listening…" : "The conversation will appear here.")
                                .font(Theme.sub)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 24)
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

// MARK: - Meters

struct MetersView: View {
    @ObservedObject var levels: AudioLevels

    var body: some View {
        HStack(spacing: 16) {
            MeterRow(label: "You", level: levels.mic, tint: Theme.accent)
            MeterRow(label: "Others", level: levels.system, tint: Theme.green)
        }
    }
}

private struct MeterRow: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(label)
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
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

// MARK: - Notes sheet

private struct NotesSheet: View {
    @ObservedObject var monitor: AudioMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Meeting Notes").font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.linearQuietCompact)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)

            ThemeDivider()

            if monitor.isGeneratingNotes {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Generating notes…\n(\(monitor.notesEngineLabel))")
                        .font(Theme.sub)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else if let error = monitor.notesError {
                ScrollView {
                    Text(error)
                        .font(Theme.body)
                        .foregroundStyle(Theme.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                Spacer()
                Button("Try again") { monitor.generateNotes() }
                    .buttonStyle(.linearQuiet)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    NotesView(notes: monitor.notes)
                        .padding(20)
                }
                ThemeDivider()
                HStack(spacing: 8) {
                    Button("Copy") { copyToPasteboard(monitor.notes) }
                        .buttonStyle(.linearQuietCompact)
                    Button("Regenerate") { monitor.generateNotes() }
                        .buttonStyle(.linearQuietCompact)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(Theme.background)
        .frame(width: 580, height: 580)
    }
}

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
