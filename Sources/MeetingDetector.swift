import SwiftUI
import AppKit
import Combine
import CoreAudio
import os

private let log = Logger(subsystem: "com.yarem.Seal", category: "Meetings")

/// Notices meetings by the one signal that actually means one: a call app is
/// using the microphone. Core Audio publishes every process that touches
/// audio, with its bundle id and a live "capturing input" flag — the same
/// process-object family the system-audio tap is built on — and observing it
/// requires no permission at all; only *capturing* audio does, and Seal
/// already holds those rights.
///
/// This replaced watching which app is frontmost. Frontmost said nothing
/// ("checking Zoom settings" prompted; a Meet call in Chrome never could,
/// because a browser in front is just browsing). Mic-in-use is right on both:
/// a dedicated call app holding the microphone *is* in a call, and a browser
/// holding it is close enough to ask.
///
/// When a meeting starts and nothing is recording, a small non-activating
/// panel offers to record — it never starts on its own unless the user has
/// explicitly turned that on in Settings, it auto-hides if ignored, and "Not
/// now" snoozes that app. When every call app has let go of the microphone
/// for a while and the recording overlapped the call, the recording is
/// stopped for the user — their notes are the next thing they want, and the
/// panel offers exactly that. A recording that never overlapped a call is
/// never touched: it's a memo, not a meeting.
final class MeetingDetector: ObservableObject {
    private let monitor: AudioMonitor
    private let settings: AppSettings
    private let openApp: () -> Void
    private var watcher: CallAudioWatcher?
    private var model = MeetingSessionModel()
    private var endCheck: DispatchWorkItem?
    private var panel: NSPanel?
    private var autoHide: DispatchWorkItem?
    private var cancellables: [AnyCancellable] = []

    /// How long every call app must stay off the microphone before the
    /// meeting counts as over. Long enough to ride out a rejoin after a drop
    /// or a hop from the browser to the Zoom app; short enough that the stop
    /// lands while the meeting is still what the user is thinking about.
    static let endDebounce: TimeInterval = 12

    init(monitor: AudioMonitor, settings: AppSettings, openApp: @escaping () -> Void) {
        self.monitor = monitor
        self.settings = settings
        self.openApp = openApp
        // Recording state feeds the session model (a recording that overlaps
        // a call is the one eligible for auto-stop) — and any start, from any
        // entry point, retires an open offer.
        monitor.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                guard let self else { return }
                self.apply(self.model.recordingChanged(running))
            }
            .store(in: &cancellables)
    }

    /// Referenced from the app body so SwiftUI actually creates the
    /// controller. Also where observation begins — not in `init`, so hosting
    /// the unit tests never registers Core Audio listeners.
    func activate() {
        guard watcher == nil else { return }
        log.notice("meeting detection active")
        let watcher = CallAudioWatcher()
        watcher.onChange = { [weak self] apps in
            guard let self else { return }
            log.notice("call apps on the microphone: \(apps.map(\.name).sorted().joined(separator: ", "), privacy: .public)\(apps.isEmpty ? "(none)" : "", privacy: .public)")
            self.apply(self.model.callAppsChanged(apps, isRecording: self.monitor.isRunning,
                                                  now: Date(), config: self.config))
        }
        self.watcher = watcher
        watcher.start()
    }

    private var config: MeetingSessionModel.Config {
        .init(offer: settings.suggestRecording,
              autoStart: settings.autoStartOnMeeting,
              autoStop: settings.autoStopAfterMeeting)
    }

    // MARK: - Effects

    private func apply(_ effects: [MeetingSessionModel.Effect]) {
        for effect in effects {
            log.notice("effect: \(String(describing: effect), privacy: .public)")
            switch effect {
            case .offer(let app):
                showStartNudge(for: app)
            case .startRecording(let app):
                monitor.start()
                monitor.showNotice("Recording started automatically — \(app.name) is in a call.", for: 12)
            case .armEndCheck:
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.endCheck = nil
                    self.apply(self.model.endCheckFired(isRecording: self.monitor.isRunning,
                                                        config: self.config))
                }
                endCheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.endDebounce, execute: work)
            case .disarmEndCheck:
                endCheck?.cancel()
                endCheck = nil
            case .stopRecording:
                monitor.stop()
            case .showEnded:
                // stop() has already published finishedMeetingID, and the main
                // window has already navigated to that meeting — opening the
                // app *is* opening the notes.
                showEndedNudge()
            case .hideNudge:
                hide()
            }
        }
    }

    // MARK: - Nudge panels

    private func showStartNudge(for app: CallApp) {
        show(MeetingNudgeView(
            icon: "record.circle", tint: Theme.red,
            // A native call app holding the mic is a meeting; a browser
            // holding it is probably one — say it with exactly that much
            // confidence.
            title: app.isBrowser ? "Meeting in \(app.name)?" : "\(app.name) meeting",
            subtitle: "Record it with Seal?",
            primaryLabel: "Record",
            primary: { [weak self] in
                self?.monitor.start()
                self?.openApp()
                self?.hide()
            },
            secondaryLabel: "Not now",
            secondary: { [weak self] in
                self?.model.snooze(app, now: Date())
                self?.hide()
            }), hideAfter: 18)
    }

    private func showEndedNudge() {
        show(MeetingNudgeView(
            icon: "checkmark", tint: Theme.green,
            title: "Meeting ended",
            subtitle: "Recording saved — open it for your notes.",
            primaryLabel: "Open",
            primary: { [weak self] in
                self?.openApp()
                self?.hide()
            },
            secondaryLabel: "Dismiss",
            secondary: { [weak self] in self?.hide() }), hideAfter: 30)
    }

    private func show(_ view: MeetingNudgeView, hideAfter seconds: TimeInterval) {
        hide()
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
        log.notice("nudge shown: \(view.title, privacy: .public)")

        // Not a permanent fixture — fade out on its own if ignored.
        let hide = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: hide)
    }

    private func hide() {
        autoHide?.cancel()
        autoHide = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - What counts as a call app

/// One entry of the allowlist, as matched from a process's bundle id.
struct CallApp: Hashable {
    let root: String       // allowlist key — snoozes and dedupe hang off this
    let name: String       // what the nudge calls it
    let isBrowser: Bool    // browsers get the hedged wording
}

/// The apps whose microphone use means "meeting". Helpers count: a browser's
/// audio lives in helper processes ("com.google.Chrome.helper", WebKit's GPU
/// process), so matching is by prefix and the whole family folds to one root.
enum CallAppDirectory {
    /// More specific roots must come before their prefixes ("…thebrowser.dia"
    /// before "…thebrowser"), because the first match wins.
    private static let apps: [(root: String, name: String, isBrowser: Bool)] = [
        ("us.zoom", "Zoom", false),   // us.zoom.xos and its helper family
        ("com.microsoft.teams2", "Teams", false),
        ("com.microsoft.teams", "Teams", false),
        ("Cisco-Systems.Spark", "Webex", false),
        ("com.cisco.webexmeetingsapp", "Webex", false),
        ("com.apple.FaceTime", "FaceTime", false),
        // FaceTime (and a Continuity phone call) capture through these
        // daemons, not the FaceTime app process itself.
        ("com.apple.TelephonyUtilities", "FaceTime", false),
        ("com.apple.avconferenced", "FaceTime", false),
        ("com.tinyspeck.slackmacgap", "Slack", false),
        ("com.hnc.Discord", "Discord", false),
        ("com.google.Chrome", "Chrome", true),
        ("com.apple.Safari", "Safari", true),
        ("com.apple.WebKit", "Safari", true),   // Safari's mic runs in WebKit helpers
        ("company.thebrowser.dia", "Dia", true),
        ("company.thebrowser", "Arc", true),
        ("com.microsoft.edgemac", "Edge", true),
        ("com.brave.Browser", "Brave", true),
        ("org.mozilla.firefox", "Firefox", true),
    ]

    /// The allowlist entry this bundle id belongs to, if any. Seal itself is
    /// not on the list, so its own capture can never look like a meeting.
    ///
    /// Case-insensitive: a browser's helpers do not spell the family name the
    /// way the app does ("company.thebrowser.Browser", but
    /// "company.thebrowser.browser.helper").
    static func match(_ bundleID: String) -> CallApp? {
        let id = bundleID.lowercased()
        for entry in apps {
            let root = entry.root.lowercased()
            if id == root || id.hasPrefix(root + ".") {
                return CallApp(root: entry.root, name: entry.name, isBrowser: entry.isBrowser)
            }
        }
        return nil
    }
}

// MARK: - Session rules

/// The decisions, kept apart from Core Audio and AppKit so they can be tested:
/// fed each observable change, answers with what to do. The rule that earns
/// the care is auto-stop — stopping someone's recording is destructive if
/// mistimed — so it fires only when a recording actually overlapped a call
/// (`linked`), the user left auto-stop on, and every call app has stayed off
/// the microphone through the whole debounce.
struct MeetingSessionModel {
    struct Config {
        var offer: Bool         // show the "Record?" nudge at all
        var autoStart: Bool     // start without asking
        var autoStop: Bool      // stop when the call ends
    }

    enum Effect: Equatable {
        case offer(CallApp)          // float the "Record it with Seal?" nudge
        case startRecording(CallApp) // auto-start, credited to this app
        case armEndCheck             // start the end-of-meeting countdown
        case disarmEndCheck          // a call app came back — cancel it
        case stopRecording           // the meeting is over: stop for the user
        case showEnded               // …and offer the saved notes
        case hideNudge
    }

    private(set) var inSession = false   // a call is on (or within the debounce of one)
    private(set) var endArmed = false
    private var linked = false           // the current recording overlapped this call
    private var snoozedUntil: [String: Date] = [:]

    /// The set of call apps holding the microphone changed.
    mutating func callAppsChanged(_ apps: Set<CallApp>, isRecording: Bool,
                                  now: Date, config: Config) -> [Effect] {
        guard apps.isEmpty else {
            var effects: [Effect] = []
            if endArmed {
                // The "ended" verdict was pending and the call resumed — a
                // drop, a rejoin, a hop between apps. Same meeting.
                endArmed = false
                effects.append(.disarmEndCheck)
            }
            if !inSession {
                inSession = true
                linked = isRecording
                if !isRecording {
                    let app = preferred(apps)
                    if snoozedUntil[app.root].map({ $0 > now }) != true {
                        if config.autoStart {
                            linked = true
                            effects.append(.startRecording(app))
                        } else if config.offer {
                            effects.append(.offer(app))
                        }
                    }
                }
            } else if isRecording {
                // The user started recording mid-call (hotkey, menu bar) —
                // that recording is this meeting's.
                linked = true
            }
            return effects
        }
        if inSession && !endArmed {
            endArmed = true
            return [.armEndCheck]
        }
        return []
    }

    /// The end countdown ran out with no call app back on the microphone.
    mutating func endCheckFired(isRecording: Bool, config: Config) -> [Effect] {
        guard endArmed else { return [] }   // stale timer — a newer event superseded it
        endArmed = false
        inSession = false
        let wasLinked = linked
        linked = false
        if wasLinked && isRecording && config.autoStop {
            return [.stopRecording, .showEnded]
        }
        // The session is over either way; an ignored offer shouldn't outlive it.
        return [.hideNudge]
    }

    /// The recording started or stopped, from any entry point.
    mutating func recordingChanged(_ running: Bool) -> [Effect] {
        if running {
            if inSession { linked = true }
            return [.hideNudge]   // whatever was being offered has happened
        }
        // A manual stop mid-call: the user decided. Unlink, so the meeting's
        // end has nothing left to stop, and don't offer again this session.
        linked = false
        return []
    }

    /// "Not now": this app stops prompting (and auto-starting) for a while.
    mutating func snooze(_ app: CallApp, now: Date) {
        snoozedUntil[app.root] = now.addingTimeInterval(600)
    }

    /// When several apps hold the microphone at once, credit the one that is
    /// most certainly a meeting: native call apps before browsers.
    private func preferred(_ apps: Set<CallApp>) -> CallApp {
        apps.min { ($0.isBrowser ? 1 : 0, $0.name) < ($1.isBrowser ? 1 : 0, $1.name) }!
    }
}

// MARK: - Core Audio observation

/// Watches which allowlisted apps hold the microphone, via Core Audio's
/// process objects. Everything runs on the main queue: listeners are
/// registered with the main dispatch queue, so `rescan` never races itself.
private final class CallAudioWatcher {
    var onChange: ((Set<CallApp>) -> Void)?
    private(set) var active: Set<CallApp> = []
    private var inputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private var poll: Timer?

    private static var listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                         &Self.listAddress, .main, block)
        if status == noErr {
            listListener = block
        } else {
            log.error("watcher: process-list listener failed (\(status, privacy: .public))")
        }
        // Belt and braces: notifications for the per-process input flag have
        // to be delivered by the HAL, and a signal this feature lives or dies
        // by should not depend on that arriving. A poll is a few dozen
        // property reads every two seconds — nothing — and guarantees the
        // flip is seen within two seconds even if no notification ever comes.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.rescan()
        }
        rescan()
    }

    /// One full pass: which processes exist, which are call apps, which of
    /// those hold the microphone. Re-run on every event — a scan is a few
    /// dozen property reads, and rebuilding from scratch keeps no state to
    /// get wrong.
    private func rescan() {
        var current: Set<CallApp> = []
        var wanted: Set<AudioObjectID> = []
        for object in Self.processObjects() {
            guard let bundleID = Self.bundleID(of: object),
                  let app = CallAppDirectory.match(bundleID) else { continue }
            wanted.insert(object)
            if Self.isRunningInput(object) { current.insert(app) }
        }

        // Keep an input-flag listener on every call-app process — the flip of
        // that flag is the meeting starting or ending — and only on those:
        // other processes' microphone habits are not this feature's business.
        for (object, block) in inputListeners where !wanted.contains(object) {
            AudioObjectRemovePropertyListenerBlock(object, &Self.inputAddress, .main, block)
            inputListeners[object] = nil
        }
        for object in wanted where inputListeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
            let status = AudioObjectAddPropertyListenerBlock(object, &Self.inputAddress, .main, block)
            if status == noErr {
                inputListeners[object] = block
            } else {
                log.error("watcher: input listener failed (\(status, privacy: .public)) on process \(object, privacy: .public)")
            }
        }

        if current != active {
            active = current
            onChange?(current)
        }
    }

    private static func processObjects() -> [AudioObjectID] {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &listAddress, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var list = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                   count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &listAddress, 0, nil, &size, &list) == noErr
        else { return [] }
        return list
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = inputAddress
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr
            && running != 0
    }
}

// MARK: - The nudge's face

/// A small floating card: what happened, and the two choices. Non-activating,
/// so answering it never steals focus from the call.
private struct MeetingNudgeView: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let primaryLabel: String
    let primary: () -> Void
    let secondaryLabel: String
    let secondary: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint).frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.bodyMedium)
                Text(subtitle)
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(primaryLabel, action: primary)
                .buttonStyle(.linearPrimaryCompact)
                .keyboardShortcut(.defaultAction)
            Button(secondaryLabel, action: secondary)
                .buttonStyle(.linearQuietCompact)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 1))
        .fixedSize()
    }
}
