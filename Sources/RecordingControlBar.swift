import SwiftUI

/// The one home for everything about the live session: proof it's working
/// (pulsing dot, elapsed timer, live waveform), the controls (Pause, Stop),
/// language & speed, and the ⋯ menu (transcript panel, discard). A floating
/// capsule docked bottom-center, so the most important controls never move,
/// no matter which panes are open. Fully local is the default and needs no
/// announcing — the privacy badge appears only as a caution when the opt-in
/// cloud notes model is on.
struct RecordingControlBar: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var settings: AppSettings
    let transcriptVisible: Bool
    let toggleTranscript: () -> Void
    let requestDiscard: () -> Void

    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 10) {
            if monitor.isRunning {
                if monitor.isPaused {
                    Text("Paused")
                        .font(Theme.metaMedium)
                        .foregroundStyle(.secondary)
                } else {
                    PulsingDot(color: Theme.red)
                }
                if let start = monitor.recordingStart {
                    RecordingTimerLabel(start: start)
                }
                LiveWaveform(levels: monitor.levels,
                             active: monitor.isRunning && !monitor.isPaused)
                    .frame(width: 88, height: 16)

                Button {
                    monitor.addHighlight()
                } label: {
                    Image(systemName: "star")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Star this moment — the notes will cover it (⇧⌘H)")

                Button(monitor.isPaused ? "Resume" : "Pause") {
                    monitor.pauseResume()
                }
                .buttonStyle(.linearQuietCompact)
                .help(monitor.isPaused ? "Resume the recording" : "Pause — nothing is transcribed until you resume")
            }

            Button(monitor.isRunning ? "Stop" : "Start Listening") {
                monitor.toggle()
            }
            .buttonStyle(startStopStyle)
            .keyboardShortcut(.defaultAction)
            .help(monitor.isRunning ? "Stop and save this meeting" : "Start listening")

            barDivider

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Microphone, language & speed")
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                SessionSettingsPopover(monitor: monitor)
            }

            Menu {
                Button(transcriptVisible ? "Hide transcript" : "Show transcript",
                       action: toggleTranscript)
                if monitor.isRunning {
                    Divider()
                    Button("Discard recording…", role: .destructive, action: requestDiscard)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")

            if settings.usingCloudNotes {
                barDivider
                PrivacyBadge(usingCloud: true, compact: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
    }

    /// One filled button at a time: red Stop while recording, indigo Start on
    /// a fresh screen, quiet Start when a finished session is still shown.
    private var startStopStyle: LinearButtonStyle {
        if monitor.isRunning { return LinearButtonStyle(kind: .primary, tint: Theme.red, compact: true) }
        if monitor.transcript.isEmpty { return LinearButtonStyle(kind: .primary, compact: true) }
        return LinearButtonStyle(kind: .quiet, compact: true)
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 14)
    }
}

// MARK: - Live waveform

/// A live, scrolling waveform. New bars enter on the right and scroll left,
/// each one colored by who's louder right now — indigo for you (mic), green
/// for the call (system audio) — so a glance confirms both sides are heard.
/// It samples the shared level meter on that meter's own ~30 Hz cadence and
/// keeps its history in local state, so it redraws itself without ever
/// touching the transcript. When paused it holds its last shape, dimmed.
struct LiveWaveform: View {
    /// Held, not observed: we react to its published mic level via onReceive
    /// so only this small Canvas redraws — never the surrounding view.
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

// MARK: - Session settings

/// Microphone, language & speed, one level below the surface. Microphone and
/// language apply live; speed needs the next meeting (it swaps the model).
struct SessionSettingsPopover: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var inputs = AudioInputsObserver()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel("Microphone")
                Picker("Microphone", selection: micSelection) {
                    Text("Automatic").tag("")
                    ForEach(inputs.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                    if isChosenMissing {
                        Text("\(settings.preferredMicName) — not connected").tag(settings.preferredMicUID)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 250)
                if monitor.isRunning {
                    Text("A switch applies to this recording immediately.")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                }
            }
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

    private var isChosenMissing: Bool {
        !settings.preferredMicUID.isEmpty
            && !inputs.devices.contains { $0.id == settings.preferredMicUID }
    }

    /// Selecting stores the preference and applies it to the live session.
    private var micSelection: Binding<String> {
        Binding(
            get: { settings.preferredMicUID },
            set: { uid in
                settings.preferredMicUID = uid
                if let name = inputs.devices.first(where: { $0.id == uid })?.name {
                    settings.preferredMicName = name
                }
                monitor.applyMicrophoneSelection()
            })
    }
}
