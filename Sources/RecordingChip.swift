import SwiftUI
import AppKit

/// The live session's one control, at the start of the Ask bar: a red dot that
/// breathes with the room, the running time, and pause, which acts at once.
/// Everything else about the session (stop, star, snap, microphone and
/// language, discard) is one click further, in the panel the dot and time
/// open, so the bar under the notes stays one bar. Stop also lives on File →
/// Stop Recording (⇧⌘R) and in the bar's "/". Fully local is the default and
/// needs no announcing; the privacy badge appears only as a caution when the
/// opt-in cloud notes model is on.
struct RecordingChip: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var settings: AppSettings
    let requestDiscard: () -> Void

    @State private var open = false

    var body: some View {
        HStack(spacing: 6) {
            if monitor.isRunning {
                chip
                    .popover(isPresented: $open, arrowEdge: .top) {
                        RecordingPanel(monitor: monitor, close: { open = false }, requestDiscard: {
                            open = false
                            requestDiscard()
                        })
                    }
            } else {
                Button { monitor.toggle() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.red).frame(width: 8, height: 8)
                        Text("Start")
                            .font(Theme.bodyMedium)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.hover))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Start listening")
            }
            if settings.usingCloudNotes {
                PrivacyBadge(usingCloud: true, compact: true)
            }
        }
        .onAppear {
            #if DEBUG
            // Screenshot hooks for an isolated demo run: open the chip's panel
            // ("open", or "menu:<row>" to drop that row's menu too), or pause.
            if DemoMode.isActive, let hook = ProcessInfo.processInfo.environment["SEAL_DEMO_CHIP"] {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if hook == "paused" {
                        monitor.pauseResume()
                    } else if hook == "open" || hook.hasPrefix("menu:") {
                        open = true
                    }
                }
            }
            #endif
        }
    }

    /// Two targets on one wash: the dot and time open the panel, and the
    /// glyph after them pauses or resumes without opening anything.
    private var chip: some View {
        HStack(spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    BreathingDot(levels: monitor.levels, active: !monitor.isPaused)
                    if monitor.isPaused {
                        Text("Paused")
                            .font(Theme.metaMedium)
                            .foregroundStyle(.secondary)
                    } else if let start = monitor.recordingStart {
                        RecordingTimerLabel(start: start)
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 4)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop, star, snap, microphone and language")
            .accessibilityLabel(monitor.isPaused ? "Recording paused" : "Recording")
            .accessibilityHint("Shows stop and the session's settings")

            PauseButton(paused: monitor.isPaused) { monitor.pauseResume() }
                // Inset so its circle sits concentric with the chip's end.
                .padding(.trailing, 4)
        }
        .background(Capsule().fill(monitor.isPaused ? Theme.hover : Theme.red.opacity(0.10)))
    }
}

/// Pause, or resume, in one click on the chip itself: neutral, so it never
/// reads as Stop, with a wash under the pointer.
private struct PauseButton: View {
    let paused: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? (paused ? Theme.hover : Theme.red.opacity(0.12)) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(paused ? "Resume" : "Pause")
        .accessibilityLabel(paused ? "Resume the recording" : "Pause the recording")
    }
}

/// What the chip opens: the session's actions as one short list, then a row
/// each for its microphone and language, then discard, set apart. Every row
/// closes the panel except the two settings, which stay to show the change.
private struct RecordingPanel: View {
    @ObservedObject var monitor: AudioMonitor
    let close: () -> Void
    let requestDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 1) {
                row("Stop and save", symbol: "stop.fill", hint: "⇧⌘R", tint: Theme.red) {
                    monitor.toggle()
                }
                row("Star this moment", symbol: "star", hint: "⇧⌘H") { monitor.addHighlight() }
                row("Snap the screen", symbol: "camera.viewfinder", hint: "⇧⌘S") { monitor.snapScreen() }
            }
            .padding(6)
            ThemeDivider()
            SessionSettingsRows(monitor: monitor)
                .padding(6)
            ThemeDivider()
            Button("Discard recording…", role: .destructive, action: requestDiscard)
                .buttonStyle(.plain)
                .font(Theme.sub)
                .foregroundStyle(Theme.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 280)
    }

    private func row(_ title: String, symbol: String, hint: String? = nil, tint: Color = .primary,
                     action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tint == .primary ? Color.secondary : tint)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                if let hint {
                    Text(hint)
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverStyle())
    }
}

/// A list row's hover wash, the way a menu shows where the pointer is.
struct RowHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(hovering || configuration.isPressed ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}

/// The recording dot: steady red, with a soft halo that swells with whatever
/// is loudest, you or the call, so a glance says the room is being heard.
/// Paused, it goes grey and still; under Reduce Motion the halo holds still.
/// It observes the level meter itself, so only this dot redraws at the
/// meter's rate.
struct BreathingDot: View {
    @ObservedObject var levels: AudioLevels
    let active: Bool
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = active && !reduceMotion ? CGFloat(min(1, max(levels.mic, levels.system))) : 0.35
        ZStack {
            Circle()
                .fill(Theme.red.opacity(active ? 0.22 : 0))
                .frame(width: size + size * 1.3 * level, height: size + size * 1.3 * level)
            Circle()
                .fill(active ? Theme.red : Color.secondary)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - Session settings

/// The session's microphone and language as two rows that name what's in use;
/// a click lists the choices as a menu, and a choice applies to this
/// recording at once. Speed swaps the model, so it can't change mid-meeting:
/// it is a preference, in Settings → Recording.
struct SessionSettingsRows: View {
    @ObservedObject var monitor: AudioMonitor
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var inputs = AudioInputsObserver()

    var body: some View {
        VStack(spacing: 1) {
            ChoiceRow(title: "Microphone", symbol: "mic", value: micValue,
                      help: "Which microphone hears you. A switch applies to this recording immediately.",
                      choices: micChoices)
            ChoiceRow(title: "Language", symbol: "globe", value: monitor.language.label,
                      help: "What the transcript listens for. A switch applies from the next words.",
                      choices: languageChoices)
        }
    }

    private var chosenDevice: AudioInputDevice? {
        inputs.devices.first { $0.id == settings.preferredMicUID }
    }

    private var micValue: String {
        if settings.preferredMicUID.isEmpty { return "Automatic" }
        return chosenDevice?.name ?? settings.preferredMicName
    }

    private var micChoices: [[MenuChoice]] {
        let uid = settings.preferredMicUID
        var devices = inputs.devices.map { device in
            MenuChoice(title: device.name, checked: device.id == uid) { chooseMic(device.id, name: device.name) }
        }
        if !uid.isEmpty, chosenDevice == nil {
            devices.append(MenuChoice(title: "\(settings.preferredMicName) — not connected", checked: true) {})
        }
        return [[MenuChoice(title: "Automatic", checked: uid.isEmpty) { chooseMic("", name: nil) }], devices]
    }

    private var languageChoices: [[MenuChoice]] {
        let all = TranscriptLanguage.allCases
        let choice = { (lang: TranscriptLanguage) in
            MenuChoice(title: lang.label, checked: monitor.language == lang) { monitor.language = lang }
        }
        return [all.filter { $0 == .auto }.map(choice), all.filter { $0 != .auto }.map(choice)]
    }

    /// Stores the preference and applies it to the live session.
    private func chooseMic(_ uid: String, name: String?) {
        settings.preferredMicUID = uid
        if let name { settings.preferredMicName = name }
        monitor.applyMicrophoneSelection()
    }
}

/// One choice in a `ChoiceRow`'s menu.
struct MenuChoice {
    let title: String
    let checked: Bool
    let choose: () -> Void
}

/// A panel row that names a setting and the value in use, drawn like the
/// rows around it; a click drops the choices below it as a native menu as
/// wide as the row, the current one ticked. Groups are set apart by a line.
struct ChoiceRow: View {
    let title: String
    let symbol: String
    let value: String
    let help: String
    let choices: [[MenuChoice]]

    @State private var anchor = MenuAnchor()

    var body: some View {
        Button { anchor.drop(choices) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.body)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Text(value)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(MenuAnchorView(anchor: anchor))
        }
        .buttonStyle(RowHoverStyle())
        .help(help)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityHint("Shows the choices")
        .onAppear {
            #if DEBUG
            // Screenshot hook for an isolated demo run: drop this row's menu
            // once the chip's panel has opened.
            if DemoMode.isActive, ProcessInfo.processInfo.environment["SEAL_DEMO_CHIP"] == "menu:\(title)" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    anchor.drop(choices)
                }
            }
            #endif
        }
    }
}

/// The AppKit view behind a `ChoiceRow`, which its menu drops from.
final class MenuAnchor {
    weak var view: NSView?
    /// Held until the next drop, so the menu outlives the click that chose.
    private var menu: NSMenu?

    func drop(_ groups: [[MenuChoice]]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for group in groups where !group.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            group.forEach { menu.addItem(ChoiceMenuItem($0)) }
        }
        menu.minimumWidth = view.bounds.width
        self.menu = menu
        let below = view.isFlipped ? view.bounds.maxY + 2 : -2
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: view)
    }
}

private final class ChoiceMenuItem: NSMenuItem {
    private let choose: () -> Void

    init(_ choice: MenuChoice) {
        choose = choice.choose
        super.init(title: choice.title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = choice.checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { choose() }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
