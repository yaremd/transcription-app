import SwiftUI
import AppKit

/// The live recording pane: language/speed settings, level meters, the live
/// transcript, and Start/Stop + Generate Notes controls. Receives the shared
/// AudioMonitor (owned by the app) rather than creating its own.
struct RecordingView: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var settings: AppSettings
    @State private var showNotes = false
    @State private var showDiscardConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            settingsRow
            meters
            transcriptArea
            userNotesArea
            if let error = monitor.errorMessage {
                Text(error)
                    .font(Theme.sub)
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 560)
        .sheet(isPresented: $showNotes) {
            NotesSheet(monitor: monitor)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LocalScribe")
                    .font(Theme.title)
                Text("Live, private, on-device transcription")
                    .font(Theme.sub)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PrivacyBadge(usingCloud: settings.usingCloudNotes)
        }
    }

    private var settingsRow: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Language")
                Picker("Language", selection: $monitor.language) {
                    ForEach(TranscriptLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 260)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Speed")
                Picker("Speed", selection: $monitor.speed) {
                    ForEach(TranscriptionSpeed.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150)
            }
            Spacer()
        }
        .disabled(monitor.isRunning)
    }

    private var meters: some View {
        // Separate subview observing AudioLevels: the ~30 Hz meter updates
        // re-render only the bars, not the whole transcript.
        MetersView(levels: monitor.levels)
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if monitor.transcript.isEmpty && monitor.liveLines.isEmpty {
                        Text(monitor.isRunning ? "Listening…" : "Your transcript will appear here.")
                            .font(Theme.sub)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(monitor.transcript) { line in
                        TranscriptRow(speaker: line.speaker, text: line.text, live: false)
                    }
                    ForEach(liveSpeakers, id: \.self) { speaker in
                        TranscriptRow(speaker: speaker, text: monitor.liveLines[speaker] ?? "", live: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .insetPanel()
            .onChange(of: monitor.transcript.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: monitor.liveLines) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(minHeight: 240)
    }

    private var liveSpeakers: [String] {
        monitor.liveLines.keys.sorted { first, _ in first == "You" }
    }

    private var userNotesArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Your notes")
                Spacer()
                Text("Generate Notes expands these using the transcript")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
            }
            TextEditor(text: $monitor.userNotes)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .frame(height: 64)
                .padding(6)
                .insetPanel(radius: 6)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(monitor.isRunning ? "Stop" : "Start Listening") {
                    monitor.toggle()
                }
                .buttonStyle(startStopStyle)
                .keyboardShortcut(.defaultAction)

                if monitor.isRunning {
                    Button(monitor.isPaused ? "Resume" : "Pause") {
                        monitor.pauseResume()
                    }
                    .buttonStyle(.linearQuiet)

                    Button("Discard", role: .destructive) {
                        showDiscardConfirm = true
                    }
                    .buttonStyle(.linearDestructive)
                }

                Spacer()

                HStack(spacing: 6) {
                    SectionLabel("Template")
                    Picker("Template", selection: $monitor.template) {
                        ForEach(NotesTemplate.all) { t in Text(t.name).tag(t) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 140)
                }

                if !monitor.isRunning && !monitor.transcript.isEmpty {
                    Button("Generate Notes") {
                        monitor.generateNotes()
                        showNotes = true
                    }
                    .buttonStyle(.linearPrimary)
                }
            }
            .confirmationDialog("Discard this recording?",
                                isPresented: $showDiscardConfirm,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { monitor.discard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The transcript and notes for this session will be deleted.")
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
        if monitor.isRunning { return LinearButtonStyle(kind: .primary, tint: Theme.red) }
        if monitor.transcript.isEmpty { return LinearButtonStyle(kind: .primary) }
        return LinearButtonStyle(kind: .quiet)
    }
}

private struct MetersView: View {
    @ObservedObject var levels: AudioLevels

    var body: some View {
        HStack(spacing: 16) {
            MeterRow(label: "You (microphone)", level: levels.mic, tint: Theme.accent)
            MeterRow(label: "Others (call / system audio)", level: levels.system, tint: Theme.green)
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

/// Small breathing dot marking the line still being spoken.
private struct PulsingDot: View {
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
