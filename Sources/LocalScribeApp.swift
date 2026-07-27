import SwiftUI
import AppKit
import Combine
import Sparkle

@main
struct LocalScribeApp: App {
    @StateObject private var store: MeetingStore
    @StateObject private var vocabulary: VocabularyStore
    @StateObject private var settings: AppSettings
    @StateObject private var monitor: AudioMonitor
    @StateObject private var pill: FloatingPillController
    @StateObject private var detector: MeetingDetector

    /// Sparkle auto-updater: checks the appcast and installs signed updates.
    private let updaterController: SPUStandardUpdaterController
    @StateObject private var updaterViewModel: CheckForUpdatesViewModel

    init() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.updaterController = updaterController
        _updaterViewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updaterController.updater))

        let store = MeetingStore()
        let vocabulary = VocabularyStore()
        let settings = AppSettings()
        let monitor = AudioMonitor(store: store, vocabulary: vocabulary, settings: settings)
        _store = StateObject(wrappedValue: store)
        _vocabulary = StateObject(wrappedValue: vocabulary)
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: monitor)
        _pill = StateObject(wrappedValue: FloatingPillController(monitor: monitor))
        _detector = StateObject(wrappedValue: MeetingDetector(monitor: monitor, settings: settings, openApp: {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        }))
    }

    var body: some Scene {
        WindowGroup {
            RootView(monitor: monitor)
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(vocabulary)
                .frame(minWidth: 860, minHeight: 620)
                // Touching the controllers here guarantees SwiftUI actually
                // creates them — an @StateObject that body never reads may never
                // be realized, and then no pill / no meeting nudge would appear.
                .onAppear { pill.ensureActive(); detector.activate() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updaterController.updater.checkForUpdates() }
                    .disabled(!updaterViewModel.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button(monitor.isRunning ? "Stop Recording" : "Start Recording") {
                    monitor.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Seal", systemImage: monitor.isRunning ? "record.circle" : "mic") {
            MenuBarView(monitor: monitor)
        }

        Settings {
            SettingsView(vocabulary: vocabulary, settings: settings)
        }
    }
}

/// Keeps the "Check for Updates…" menu item enabled only when Sparkle is
/// actually able to check (updater started, not mid-check).
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

// MARK: - Floating recording pill

/// Shows a small always-on-top pill while a recording runs in the background
/// (Seal not the active app) — the Zoom/Granola pattern: proof the app
/// still hears you, a pause/resume button, and a click brings the app back.
/// Hidden the moment the app becomes active or the recording stops.
final class FloatingPillController: ObservableObject {
    private var panel: NSPanel?
    private let monitor: AudioMonitor
    private var cancellables: [AnyCancellable] = []

    init(monitor: AudioMonitor) {
        self.monitor = monitor
        let center = NotificationCenter.default
        // App focus, window minimize/restore, and window close all change
        // whether the user can currently see the app — re-evaluate on each.
        let triggers: [Notification.Name] = [
            NSApplication.didResignActiveNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in triggers {
            center.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
        }
        // $isRunning emits before the property is set — use the emitted value.
        monitor.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in self?.refresh(running: running) }
            .store(in: &cancellables)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Called once from the app body — makes sure the controller exists and
    /// has evaluated the current window state.
    func ensureActive() {
        refresh()
    }

    /// The pill shows whenever a recording runs and the app isn't visibly in
    /// front of the user. "Visibly in front" is judged directly from window
    /// state: the app is active AND at least one real (titled) window is
    /// actually on screen — a minimized, hidden, or closed window is not.
    /// Judging it this way is robust against the invisible helper windows
    /// AppKit/SwiftUI keep around (status-bar items, released Settings
    /// windows), which used to be able to masquerade as "the" main window.
    private func refresh(running: Bool? = nil) {
        let isRecording = running ?? monitor.isRunning
        // The Dock icon carries a REC badge for the whole session — visible
        // reassurance even when the pill is hidden or on another screen.
        NSApp.dockTile.badgeLabel = isRecording ? "REC" : nil
        guard isRecording else { hide(); return }
        let visiblyInFront = NSApp.isActive && NSApp.windows.contains { window in
            !(window is NSPanel)
                && window.styleMask.contains(.titled)
                && window.isVisible
                && !window.isMiniaturized
        }
        visiblyInFront ? hide() : show()
    }

    private func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let content = FloatingPillView(monitor: monitor, levels: monitor.levels) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if let window = self?.mainWindow {
                if window.isMiniaturized { window.deminiaturize(nil) }
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
            // Only the glyph and the pause control are buttons; everything
            // else (dots, padding, capsule) is free surface, so the panel's
            // isMovableByWindowBackground lets the user drag the pill
            // anywhere on the screen.
            Button(action: openApp) {
                ZStack {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 22, height: 22)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Open Seal")

            // Elapsed time — the same quiet reassurance as the in-app control
            // bar. Reserved width so the panel never clips as digits grow.
            if let start = monitor.recordingStart {
                RecordingTimerLabel(start: start)
                    .frame(minWidth: 44, alignment: .leading)
                    .opacity(monitor.isPaused ? 0.5 : 1)
            }

            LevelDots(level: monitor.isPaused ? 0 : levels.mic,
                      dimmed: monitor.isPaused)
                .help("Drag to move")

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
