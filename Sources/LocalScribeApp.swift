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
    @StateObject private var entitlements: EntitlementService

    /// Sparkle auto-updater: checks the appcast and installs signed updates.
    /// The policy delegate enforces the perpetual license's update window —
    /// Sparkle holds delegates weakly, so the App must retain it here.
    private let updaterController: SPUStandardUpdaterController
    private let updatePolicy: UpdatePolicy
    @StateObject private var updaterViewModel: CheckForUpdatesViewModel

    /// True when the test runner launched this process. The app hosts the unit
    /// tests, so its startup work runs at test startup too — and a test run has
    /// no business fetching the appcast, listening for meetings, or putting a
    /// floating panel on screen. (What actually blocked the runner was the
    /// Keychain read in `AppSettings.init`; see `Keychain.isUnderTest`.)
    /// The library window's scene, so File → New Meeting can bring it back.
    static let mainWindowID = "main"

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        // Before anything can ask for a speech model: earlier builds let
        // WhisperKit default its cache into ~/Documents, where iCloud Drive
        // syncs it. Moving it is cheap when there is nothing to move, and it
        // has to happen before the first load or the models download twice.
        if !Self.isRunningTests { WhisperModelStore.migrateLegacyCacheIfNeeded() }

        // Entitlements come first: the update policy consults them, and the
        // updater may check the appcast as soon as it starts.
        let entitlements = EntitlementService()
        let updatePolicy = UpdatePolicy(entitlements: entitlements)
        self.updatePolicy = updatePolicy
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: !Self.isRunningTests, updaterDelegate: updatePolicy, userDriverDelegate: nil)
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
        _entitlements = StateObject(wrappedValue: entitlements)
        _detector = StateObject(wrappedValue: MeetingDetector(monitor: monitor, settings: settings, openApp: {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        }))
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView(monitor: monitor)
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(vocabulary)
                .environmentObject(entitlements)
                // The single upgrade surface: opened by any locked control.
                .sheet(item: $entitlements.upgradePrompt) { prompt in
                    UpgradeSheet(highlighted: prompt.feature)
                        .environmentObject(entitlements)
                }
                .frame(minWidth: 860, minHeight: 620)
                // Touching the controllers here guarantees SwiftUI actually
                // creates them — an @StateObject that body never reads may never
                // be realized, and then no pill / no meeting nudge would appear.
                .onAppear {
                    // A demo run must never listen for calls: with auto-start
                    // on, a screenshot instance once recorded 20 s of whatever
                    // the Mac was playing into its scratch container.
                    guard !Self.isRunningTests, !DemoMode.isActive else { return }
                    pill.ensureActive()
                    detector.activate()
                }
        }
        .commands {
            NewMeetingCommands(monitor: monitor)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updaterController.updater.checkForUpdates() }
                    .disabled(!updaterViewModel.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button(monitor.isRunning ? "Stop Recording" : "Start Recording") {
                    monitor.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Star This Moment") { monitor.addHighlight() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(!monitor.isRunning)
                Button("Snap the Screen") { monitor.snapScreen() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!monitor.isRunning)
            }
        }

        MenuBarExtra("Seal", systemImage: monitor.isRunning ? "record.circle" : "mic") {
            MenuBarView(monitor: monitor, entitlements: entitlements)
        }

        Settings {
            SettingsView(vocabulary: vocabulary, settings: settings, entitlements: entitlements, monitor: monitor)
        }
    }
}

/// File → New Meeting (⌘N). The page's own New meeting is the sidebar's first
/// row, and a sidebar can be hidden, so the shortcut belongs to the menu. It
/// replaces File → New Window: Seal is one library in one window. With that
/// window closed, it starts listening and opens it on the live meeting.
struct NewMeetingCommands: Commands {
    let monitor: AudioMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Meeting") {
                if RootView.onScreen > 0 {
                    NotificationCenter.default.post(name: .sealNewMeeting, object: nil)
                } else {
                    if !monitor.isRunning {
                        monitor.resetFinishedSession()
                        monitor.start()
                    }
                    openWindow(id: LocalScribeApp.mainWindowID)
                }
            }
            .keyboardShortcut("n", modifiers: .command)
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

// MARK: - Floating recording tab

/// While a recording runs and Seal isn't in front, a tab waits against the
/// edge of the screen: proof the app still hears you, made as small as it can
/// be. Under the pointer it slides out with the time, pause, stop, star, snap
/// and a note box (see `EdgeTabView`); dragged, it settles on the nearer side
/// and remembers the side and the height it was left at. Hidden the moment
/// the app is visibly in front or the recording stops.
final class FloatingPillController: ObservableObject {
    private var panel: EdgeTabPanel?
    private let monitor: AudioMonitor
    private let model: EdgeTabModel
    private var cancellables: [AnyCancellable] = []
    private var collapseWork: DispatchWorkItem?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    private static let sideKey = "edgeTabSide"
    private static let heightKey = "edgeTabHeight"
    private static let collapsedWidth: CGFloat = 18
    private static let expandedWidth: CGFloat = 420

    init(monitor: AudioMonitor) {
        self.monitor = monitor
        model = EdgeTabModel(side: EdgeSide(rawValue: UserDefaults.standard.string(forKey: Self.sideKey) ?? "") ?? .right)
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
        // The note box let go of the cursor: the tab can fold away again.
        model.$noteFocused
            .dropFirst()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleCollapse() }
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

    /// The tab shows whenever a recording runs and the app isn't visibly in
    /// front of the user. "Visibly in front" is judged directly from window
    /// state: the app is active AND at least one real (titled) window is
    /// actually on screen — a minimized, hidden, or closed window is not.
    /// Judging it this way is robust against the invisible helper windows
    /// AppKit/SwiftUI keep around (status-bar items, released Settings
    /// windows), which used to be able to masquerade as "the" main window.
    private func refresh(running: Bool? = nil) {
        let isRecording = running ?? monitor.isRunning
        // The Dock icon carries a REC badge for the whole session — visible
        // reassurance even when the tab is hidden or on another screen.
        NSApp.dockTile.badgeLabel = isRecording ? "REC" : nil
        guard isRecording else { hide(); return }
        #if DEBUG
        // Screenshot hook for an isolated demo run: show the tab even with the
        // app in front, folded or (`expanded`) open.
        if DemoMode.isActive, let mode = ProcessInfo.processInfo.environment["SEAL_DEMO_PILL"] {
            show()
            if mode == "expanded" { expand() }
            return
        }
        #endif
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
        place(width: model.expanded ? Self.expandedWidth : Self.collapsedWidth)
        panel?.orderFrontRegardless()
    }

    private func hide() {
        collapseWork?.cancel()
        model.expanded = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> EdgeTabPanel {
        let content = EdgeTabView(
            model: model, monitor: monitor,
            openApp: { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                if let window = self?.mainWindow {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                }
            },
            hover: { [weak self] inside in self?.hover(inside) },
            drag: { [weak self] phase in self?.drag(phase) },
            endNote: { [weak self] in
                self?.panel?.makeFirstResponder(nil)
                self?.scheduleCollapse()
            })
        let hosting = NSHostingView(rootView: content)
        // The panel's size is this controller's to set; left to itself the
        // hosting view would resize the window to its content on every change.
        hosting.sizingOptions = []

        // Non-activating: its buttons work without stealing focus from the
        // app the user is actually in (the call, the browser). It still takes
        // the keyboard for the note box, without bringing Seal forward.
        let size = NSSize(width: Self.collapsedWidth, height: EdgeTabView.faceHeight)
        let panel = EdgeTabPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false   // the face drags itself, and settles on an edge
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Puts the panel against its side of the screen it is on, at the height
    /// it was left at (near the top the first time).
    private func place(width: CGFloat, animate: Bool = false) {
        guard let panel, let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let height = EdgeTabView.faceHeight
        let fraction = UserDefaults.standard.object(forKey: Self.heightKey) as? Double ?? 0.8
        let y = min(max(frame.minY + frame.height * CGFloat(fraction) - height / 2, frame.minY + 8),
                    frame.maxY - height - 8)
        let x = model.side == .right ? frame.maxX - width : frame.minX
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: animate)
        panel.invalidateShadow()
    }

    // MARK: Opening and folding

    private func hover(_ inside: Bool) {
        if inside {
            collapseWork?.cancel()
            expand()
        } else {
            scheduleCollapse()
        }
    }

    /// The panel grows first, then the face opens inside it, so nothing is
    /// ever drawn outside the window.
    private func expand() {
        guard !model.expanded else { return }
        place(width: Self.expandedWidth)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { model.expanded = true }
    }

    private func scheduleCollapse(after delay: TimeInterval = 0.7) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The face folds first, then the panel shrinks to the sliver. Never while
    /// a note is being typed or the tab is being dragged.
    private func collapse() {
        #if DEBUG
        if DemoMode.isActive, ProcessInfo.processInfo.environment["SEAL_DEMO_PILL"] == "expanded" { return }
        #endif
        guard model.expanded, !model.noteFocused, !model.dragging else { return }
        withAnimation(.easeOut(duration: 0.16)) { model.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.place(width: Self.collapsedWidth)
        }
    }

    // MARK: Dragging

    /// Follows the pointer anywhere; let go, it settles on the nearer side of
    /// the screen it was dropped on, at that height, and remembers both.
    private func drag(_ phase: EdgeTabDrag) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            if dragStart == nil {
                dragStart = (mouse, panel.frame.origin)
                model.dragging = true
                collapseWork?.cancel()
            }
            guard let start = dragStart else { return }
            panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                         y: start.origin.y + mouse.y - start.mouse.y))
        case .ended:
            dragStart = nil
            model.dragging = false
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? panel.screen else { return }
            let frame = screen.visibleFrame
            let side: EdgeSide = panel.frame.midX < frame.midX ? .left : .right
            let fraction = min(max((panel.frame.midY - frame.minY) / frame.height, 0.05), 0.95)
            UserDefaults.standard.set(side.rawValue, forKey: Self.sideKey)
            UserDefaults.standard.set(Double(fraction), forKey: Self.heightKey)
            model.side = side
            let width = panel.frame.width
            let y = frame.minY + frame.height * fraction - panel.frame.height / 2
            let x = side == .right ? frame.maxX - width : frame.minX
            panel.setFrame(NSRect(x: x, y: y, width: width, height: panel.frame.height), display: true, animate: true)
            panel.invalidateShadow()
            scheduleCollapse(after: 1.2)
        }
    }
}
