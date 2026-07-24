import SwiftUI
import AppKit
import Combine

/// Notices when a call app (Zoom, Teams, Webex, FaceTime) comes to the front
/// and, if the user isn't already recording, floats a small non-activating
/// prompt offering to record. It never starts on its own, is easy to dismiss,
/// and snoozes per app so it can't nag. Off entirely when the setting is off.
final class MeetingDetector: ObservableObject {
    private let monitor: AudioMonitor
    private let settings: AppSettings
    private let openApp: () -> Void
    private var panel: NSPanel?
    private var autoHide: DispatchWorkItem?
    private var snoozedUntil: [String: Date] = [:]
    private var cancellables: [AnyCancellable] = []

    /// Bundle id → friendly name. Native call apps only: browser-based Meet
    /// can't be told apart from ordinary browsing without false positives.
    private static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.apple.FaceTime": "FaceTime",
    ]

    init(monitor: AudioMonitor, settings: AppSettings, openApp: @escaping () -> Void) {
        self.monitor = monitor
        self.settings = settings
        self.openApp = openApp
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handleActivation(note) }
            .store(in: &cancellables)
        // Recording started (from anywhere) → drop any open nudge.
        monitor.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in if running { self?.hide() } }
            .store(in: &cancellables)
    }

    /// Referenced from the app body so SwiftUI actually creates the controller.
    func activate() {}

    private func handleActivation(_ note: Notification) {
        guard settings.suggestRecording, !monitor.isRunning else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let name = Self.meetingApps[bundleID] else { return }
        if let until = snoozedUntil[bundleID], until > Date() { return }
        show(appName: name, bundleID: bundleID)
    }

    private func show(appName: String, bundleID: String) {
        hide()
        let view = MeetingNudgeView(
            appName: appName,
            record: { [weak self] in
                self?.monitor.start()
                self?.openApp()
                self?.hide()
            },
            dismiss: { [weak self] in
                self?.snoozedUntil[bundleID] = Date().addingTimeInterval(600)   // 10 min
                self?.hide()
            })

        let hosting = NSHostingView(rootView: view)
        var size = hosting.fittingSize
        if size.width < 100 { size = NSSize(width: 300, height: 56) }
        hosting.frame = NSRect(origin: .zero, size: size)

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
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: frame.maxY - size.height - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        // Not a permanent fixture — fade out on its own if ignored.
        let hide = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 18, execute: hide)
    }

    private func hide() {
        autoHide?.cancel()
        autoHide = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The nudge's face: a red dot, what was detected, and the two choices.
private struct MeetingNudgeView: View {
    let appName: String
    let record: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.red).frame(width: 24, height: 24)
                Image(systemName: "record.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(appName) meeting")
                    .font(Theme.bodyMedium)
                Text("Record it with Seal?")
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Record", action: record)
                .buttonStyle(.linearPrimaryCompact)
                .keyboardShortcut(.defaultAction)
            Button("Not now", action: dismiss)
                .buttonStyle(.linearQuietCompact)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 1))
        .fixedSize()
    }
}
