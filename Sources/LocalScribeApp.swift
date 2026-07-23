import SwiftUI
import AppKit
import Combine

@main
struct LocalScribeApp: App {
    @StateObject private var store: MeetingStore
    @StateObject private var vocabulary: VocabularyStore
    @StateObject private var settings: AppSettings
    @StateObject private var monitor: AudioMonitor
    @StateObject private var pill: FloatingPillController

    init() {
        let store = MeetingStore()
        let vocabulary = VocabularyStore()
        let settings = AppSettings()
        let monitor = AudioMonitor(store: store, vocabulary: vocabulary, settings: settings)
        _store = StateObject(wrappedValue: store)
        _vocabulary = StateObject(wrappedValue: vocabulary)
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: monitor)
        _pill = StateObject(wrappedValue: FloatingPillController(monitor: monitor))
    }

    var body: some Scene {
        WindowGroup {
            RootView(monitor: monitor)
                .environmentObject(store)
                .environmentObject(settings)
                .frame(minWidth: 860, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(monitor.isRunning ? "Stop Recording" : "Start Recording") {
                    monitor.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("LocalScribe", systemImage: monitor.isRunning ? "record.circle" : "mic") {
            MenuBarView(monitor: monitor)
        }

        Settings {
            SettingsView(vocabulary: vocabulary, settings: settings)
        }
    }
}

// MARK: - Floating recording pill

/// Shows a small always-on-top pill while a recording runs in the background
/// (LocalScribe not the active app) — the Zoom/Granola pattern: proof the app
/// still hears you, a pause/resume button, and a click brings the app back.
/// Hidden the moment the app becomes active or the recording stops.
final class FloatingPillController: ObservableObject {
    private var panel: NSPanel?
    private let monitor: AudioMonitor
    private var cancellables: [AnyCancellable] = []

    init(monitor: AudioMonitor) {
        self.monitor = monitor
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // $isRunning emits before the property is set — use the emitted value.
        monitor.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in self?.refresh(running: running) }
            .store(in: &cancellables)
    }

    private func refresh(running: Bool? = nil) {
        let isRecording = running ?? monitor.isRunning
        if isRecording && !NSApp.isActive {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let content = FloatingPillView(monitor: monitor, levels: monitor.levels) {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        let hosting = NSHostingView(rootView: content)
        var size = hosting.fittingSize
        if size.width < 60 { size = NSSize(width: 180, height: 40) }
        hosting.frame = NSRect(origin: .zero, size: size)

        // Non-activating: its buttons work without stealing focus from the
        // app the user is actually in (the call, the browser).
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 18,
                                         y: frame.maxY - size.height - 18))
        }
        return panel
    }
}

/// The pill's face: mic glyph, live level dots, pause/resume. Clicking the
/// glyph/dots area opens the app.
private struct FloatingPillView: View {
    @ObservedObject var monitor: AudioMonitor
    @ObservedObject var levels: AudioLevels
    let openApp: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: openApp) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 22, height: 22)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    LevelDots(level: monitor.isPaused ? 0 : levels.mic,
                              dimmed: monitor.isPaused)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open LocalScribe")

            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1, height: 16)

            Button {
                monitor.pauseResume()
            } label: {
                Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(monitor.isPaused ? "Resume recording" : "Pause recording")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        .fixedSize()
    }
}

/// The "it hears you" dots: filled count follows the live mic level.
private struct LevelDots: View {
    let level: Float
    var dimmed = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { index in
                Circle()
                    .fill(Float(index) < level * 8 ? Theme.accent : Theme.track)
                    .frame(width: 4, height: 4)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
        .animation(.linear(duration: 0.08), value: level)
    }
}
