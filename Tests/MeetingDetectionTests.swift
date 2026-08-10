import XCTest
@testable import Seal

/// The meeting-detection rules, exercised without Core Audio or AppKit: the
/// allowlist mapping and the session model that decides when to offer, when to
/// auto-start, and — the destructive one — when a recording may be stopped on
/// the user's behalf.
final class MeetingDetectionTests: XCTestCase {

    // MARK: - Allowlist

    /// A browser's microphone use surfaces in helper processes; the whole
    /// family must fold to one app.
    func testBrowserHelpersFoldToTheirBrowser() {
        XCTAssertEqual(CallAppDirectory.match("com.google.Chrome")?.name, "Chrome")
        XCTAssertEqual(CallAppDirectory.match("com.google.Chrome.helper")?.name, "Chrome")
        XCTAssertEqual(CallAppDirectory.match("com.google.Chrome.helper.renderer")?.root,
                       "com.google.Chrome")
        XCTAssertEqual(CallAppDirectory.match("com.apple.WebKit.GPU")?.name, "Safari",
                       "Safari's capture lives in WebKit's helper processes")
        XCTAssertEqual(CallAppDirectory.match("company.thebrowser.Browser")?.name, "Arc")
    }

    func testNativeCallAppsAreNotBrowsers() {
        let zoom = CallAppDirectory.match("us.zoom.xos")
        XCTAssertEqual(zoom?.name, "Zoom")
        XCTAssertEqual(zoom?.isBrowser, false)
        XCTAssertEqual(CallAppDirectory.match("us.zoom.caphost")?.name, "Zoom",
                       "Zoom's helper family belongs to Zoom")
        XCTAssertEqual(CallAppDirectory.match("com.microsoft.teams2")?.name, "Teams")
        XCTAssertEqual(CallAppDirectory.match("com.google.Chrome")?.isBrowser, true)
    }

    /// FaceTime (and a Continuity phone call) capture through system daemons,
    /// not the FaceTime app process — those daemons are the call.
    func testAppleCallDaemonsCountAsFaceTime() {
        XCTAssertEqual(CallAppDirectory.match("com.apple.TelephonyUtilities")?.name, "FaceTime")
        XCTAssertEqual(CallAppDirectory.match("com.apple.avconferenced")?.name, "FaceTime")
    }

    /// Real bundle ids seen on this machine: Arc's helpers lower-case the
    /// family name, and Dia shares Arc's vendor prefix but is its own browser.
    func testMatchingIsCaseInsensitiveAndMostSpecificWins() {
        XCTAssertEqual(CallAppDirectory.match("company.thebrowser.browser.helper")?.name, "Arc")
        XCTAssertEqual(CallAppDirectory.match("company.thebrowser.dia")?.name, "Dia")
        XCTAssertEqual(CallAppDirectory.match("company.thebrowser.dia.helper")?.name, "Dia")
    }

    /// Prefix matching must not swallow neighbours: a bundle id that merely
    /// begins with the same letters is a different app.
    func testPrefixMatchingRequiresAComponentBoundary() {
        XCTAssertNil(CallAppDirectory.match("us.zoomerang.app"))
        XCTAssertNil(CallAppDirectory.match("com.google.Chromecast"))
    }

    /// Seal itself uses the microphone on every recording; it must never read
    /// as a meeting. Neither should the apps that grab the mic outside calls.
    func testOwnProcessAndNonCallAppsNeverMatch() {
        XCTAssertNil(CallAppDirectory.match("com.yarem.Seal"))
        XCTAssertNil(CallAppDirectory.match("com.apple.VoiceMemos"))
        XCTAssertNil(CallAppDirectory.match("com.loom.desktop"))
    }

    // MARK: - Session model

    private let zoom = CallApp(root: "us.zoom.xos", name: "Zoom", isBrowser: false)
    private let chrome = CallApp(root: "com.google.Chrome", name: "Chrome", isBrowser: true)
    private let ask = MeetingSessionModel.Config(offer: true, autoStart: false, autoStop: true)
    private let auto = MeetingSessionModel.Config(offer: true, autoStart: true, autoStop: true)
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testACallStartingOffersOnce() {
        var model = MeetingSessionModel()
        XCTAssertEqual(model.callAppsChanged([zoom], isRecording: false, now: t0, config: ask),
                       [.offer(zoom)])
        // Membership churn mid-call (a helper appears, a second app joins) is
        // the same meeting — no second offer.
        XCTAssertEqual(model.callAppsChanged([zoom, chrome], isRecording: false, now: t0, config: ask),
                       [])
    }

    func testANativeAppIsCreditedOverABrowser() {
        var model = MeetingSessionModel()
        let effects = model.callAppsChanged([chrome, zoom], isRecording: false, now: t0, config: ask)
        XCTAssertEqual(effects, [.offer(zoom)],
                       "a native call app is a meeting for sure; the browser only probably")
    }

    func testAutoStartSkipsTheOffer() {
        var model = MeetingSessionModel()
        XCTAssertEqual(model.callAppsChanged([chrome], isRecording: false, now: t0, config: auto),
                       [.startRecording(chrome)])
    }

    func testSnoozeSilencesOfferAndAutoStart() {
        var model = MeetingSessionModel()
        _ = model.callAppsChanged([zoom], isRecording: false, now: t0, config: ask)
        model.snooze(zoom, now: t0)
        // The call ends and a new one starts five minutes later: still snoozed.
        _ = model.callAppsChanged([], isRecording: false, now: t0, config: ask)
        _ = model.endCheckFired(isRecording: false, config: ask)
        let later = t0.addingTimeInterval(300)
        XCTAssertEqual(model.callAppsChanged([zoom], isRecording: false, now: later, config: auto), [])
        // …but not forever.
        _ = model.callAppsChanged([], isRecording: false, now: later, config: ask)
        _ = model.endCheckFired(isRecording: false, config: ask)
        let muchLater = t0.addingTimeInterval(700)
        XCTAssertEqual(model.callAppsChanged([zoom], isRecording: false, now: muchLater, config: ask),
                       [.offer(zoom)])
    }

    /// The destructive path: a recording that overlapped the call stops when
    /// the call ends, and the saved notes are offered.
    func testAMeetingLinkedRecordingStopsWhenTheCallEnds() {
        var model = MeetingSessionModel()
        _ = model.callAppsChanged([zoom], isRecording: false, now: t0, config: ask)
        _ = model.recordingChanged(true)   // user pressed Record on the nudge
        XCTAssertEqual(model.callAppsChanged([], isRecording: true, now: t0, config: ask),
                       [.armEndCheck])
        XCTAssertEqual(model.endCheckFired(isRecording: true, config: ask),
                       [.stopRecording, .showEnded])
    }

    /// A memo is not a meeting: a recording that never overlapped a call app
    /// must never be auto-stopped, whatever the microphone does elsewhere.
    func testARecordingOutsideAnyCallIsNeverAutoStopped() {
        var model = MeetingSessionModel()
        _ = model.recordingChanged(true)   // recording with no call anywhere
        XCTAssertEqual(model.callAppsChanged([], isRecording: true, now: t0, config: ask), [],
                       "no session ever existed — nothing to arm")
    }

    /// A drop-and-rejoin (or a hop from browser to app) within the debounce is
    /// the same meeting: the pending stop must be cancelled.
    func testARejoinWithinTheDebounceCancelsTheStop() {
        var model = MeetingSessionModel()
        _ = model.callAppsChanged([chrome], isRecording: false, now: t0, config: ask)
        _ = model.recordingChanged(true)
        XCTAssertEqual(model.callAppsChanged([], isRecording: true, now: t0, config: ask),
                       [.armEndCheck])
        XCTAssertEqual(model.callAppsChanged([zoom], isRecording: true, now: t0, config: ask),
                       [.disarmEndCheck])
        // The disarm made the old timer stale; if it fires anyway, nothing happens.
        XCTAssertEqual(model.endCheckFired(isRecording: true, config: ask), [])
    }

    /// Starting mid-call (hotkey, menu bar) links the recording to the meeting
    /// just as surely as starting from the nudge.
    func testARecordingStartedMidCallIsLinked() {
        var model = MeetingSessionModel()
        _ = model.callAppsChanged([zoom], isRecording: false, now: t0, config: ask)
        _ = model.recordingChanged(true)   // ⌘⇧R, not the nudge
        _ = model.callAppsChanged([], isRecording: true, now: t0, config: ask)
        XCTAssertEqual(model.endCheckFired(isRecording: true, config: ask),
                       [.stopRecording, .showEnded])
    }

    /// A recording that was running before the call began is the meeting's
    /// recording too — the user pressed record early, then joined.
    func testARecordingRunningBeforeTheCallIsLinked() {
        var model = MeetingSessionModel()
        XCTAssertEqual(model.callAppsChanged([zoom], isRecording: true, now: t0, config: ask), [],
                       "already recording — nothing to offer")
        _ = model.callAppsChanged([], isRecording: true, now: t0, config: ask)
        XCTAssertEqual(model.endCheckFired(isRecording: true, config: ask),
                       [.stopRecording, .showEnded])
    }

    /// The user stopping by hand is a decision: the meeting's end then has
    /// nothing left to stop.
    func testAManualStopUnlinksTheRecording() {
        var model = MeetingSessionModel()
        _ = model.callAppsChanged([zoom], isRecording: false, now: t0, config: ask)
        _ = model.recordingChanged(true)
        _ = model.recordingChanged(false)   // stopped mid-call, deliberately
        _ = model.callAppsChanged([], isRecording: false, now: t0, config: ask)
        XCTAssertEqual(model.endCheckFired(isRecording: false, config: ask), [.hideNudge])
    }

    /// Auto-stop off means exactly that, even for a linked recording.
    func testAutoStopOffLeavesTheRecordingRunning() {
        var model = MeetingSessionModel()
        let noStop = MeetingSessionModel.Config(offer: true, autoStart: false, autoStop: false)
        _ = model.callAppsChanged([zoom], isRecording: false, now: t0, config: noStop)
        _ = model.recordingChanged(true)
        _ = model.callAppsChanged([], isRecording: true, now: t0, config: noStop)
        XCTAssertEqual(model.endCheckFired(isRecording: true, config: noStop), [.hideNudge])
    }

    /// Once a session fully ends, the next call is a fresh one: it offers again.
    func testANewCallAfterASessionEndsOffersAgain() {
        var model = MeetingSessionModel()
        _ = model.callAppsChanged([zoom], isRecording: false, now: t0, config: ask)
        _ = model.callAppsChanged([], isRecording: false, now: t0, config: ask)
        _ = model.endCheckFired(isRecording: false, config: ask)
        XCTAssertEqual(model.callAppsChanged([zoom], isRecording: false, now: t0, config: ask),
                       [.offer(zoom)])
    }

    /// Offers respect the master switch.
    func testOffersOffMeansSilence() {
        var model = MeetingSessionModel()
        let quiet = MeetingSessionModel.Config(offer: false, autoStart: false, autoStop: true)
        XCTAssertEqual(model.callAppsChanged([zoom], isRecording: false, now: t0, config: quiet), [])
    }
}
