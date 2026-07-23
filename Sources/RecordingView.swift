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
        VStack(spacing: 14) {
            header
            settingsRow
            meters
            transcriptArea
            userNotesArea
            if let error = monitor.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 560)
        .sheet(isPresented: $showNotes) {
            NotesSheet(monitor: monitor)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("LocalScribe")
                .font(.title2).bold()
            Text("Live, private, on-device transcription")
                .font(.callout)
                .foregroundStyle(.secondary)
            PrivacyBadge(usingCloud: settings.usingCloudNotes)
        }
    }

    private var settingsRow: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(spacing: 3) {
                Text("Language").font(.caption2).foregroundStyle(.secondary)
                Picker("Language", selection: $monitor.language) {
                    ForEach(TranscriptLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            VStack(spacing: 3) {
                Text("Speed").font(.caption2).foregroundStyle(.secondary)
                Picker("Speed", selection: $monitor.speed) {
                    ForEach(TranscriptionSpeed.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
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
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Your notes — jot anything; Generate Notes will expand these using the transcript.")
                .font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: $monitor.userNotes)
                .font(.callout)
                .frame(height: 64)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Text(monitor.modelStatus.isEmpty ? monitor.statusMessage : "\(monitor.statusMessage)  ·  \(monitor.modelStatus)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Template").font(.caption).foregroundStyle(.secondary)
                Picker("Template", selection: $monitor.template) {
                    ForEach(NotesTemplate.all) { t in Text(t.name).tag(t) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
            }

            HStack(spacing: 12) {
                Button(monitor.isRunning ? "Stop" : "Start Listening") {
                    monitor.toggle()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

                if monitor.isRunning {
                    Button(monitor.isPaused ? "Resume" : "Pause") {
                        monitor.pauseResume()
                    }
                    .controlSize(.large)

                    Button("Discard", role: .destructive) {
                        showDiscardConfirm = true
                    }
                    .controlSize(.large)
                }

                if !monitor.isRunning && !monitor.transcript.isEmpty {
                    Button("Generate Notes") {
                        monitor.generateNotes()
                        showNotes = true
                    }
                    .controlSize(.large)
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
        }
    }
}

private struct MetersView: View {
    @ObservedObject var levels: AudioLevels

    var body: some View {
        VStack(spacing: 8) {
            MeterRow(label: "You (microphone)", level: levels.mic, tint: .blue)
            MeterRow(label: "Others (call / system audio)", level: levels.system, tint: .green)
        }
    }
}

private struct MeterRow: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(tint)
                        .frame(width: max(3, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(height: 14)
        }
    }
}

struct TranscriptRow: View {
    let speaker: String
    let text: String
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(speaker.uppercased())
                    .font(.caption2).bold()
                    .foregroundStyle(speaker == "You" ? Color.blue : Color.green)
                if live {
                    PulsingDot(color: speaker == "You" ? .blue : .green)
                }
            }
            Text(text)
                .font(.body)
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
        VStack(spacing: 12) {
            HStack {
                Text("Meeting Notes").font(.title3).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            if monitor.isGeneratingNotes {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Generating notes…\n(\(monitor.notesEngineLabel))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else if let error = monitor.notesError {
                ScrollView {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Button("Try again") { monitor.generateNotes() }
            } else {
                ScrollView {
                    NotesView(notes: monitor.notes).padding(4)
                }
                HStack {
                    Button("Copy") { copyToPasteboard(monitor.notes) }
                    Button("Regenerate") { monitor.generateNotes() }
                    Spacer()
                }
            }
        }
        .padding(20)
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
            Text(clean(String(line.dropFirst(4)))).font(.subheadline).bold().padding(.top, 4)
        } else if line.hasPrefix("## ") {
            Text(clean(String(line.dropFirst(3)))).font(.headline).padding(.top, 6)
        } else if line.hasPrefix("# ") {
            Text(clean(String(line.dropFirst(2)))).font(.title3).bold().padding(.top, 6)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(clean(String(line.dropFirst(2))))
            }
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 3)
        } else {
            Text(clean(line))
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
