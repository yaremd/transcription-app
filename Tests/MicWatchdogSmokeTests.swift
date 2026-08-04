import XCTest
import AVFoundation
@testable import Seal

/// Verifies that the microphone stays *supervised* for a whole session, not
/// just for the few seconds it takes to prove the device works once.
///
/// The regression this guards: the watchdog used to disarm itself the moment it
/// saw audio ("audible and flowing; nothing left to watch this session"). On
/// 2026-08-03 a Studio Display microphone delivered 1.6 seconds and stopped;
/// the watchdog had already retired, so nothing noticed for the remaining 46
/// minutes and the user's entire side of the meeting was lost. A liveness check
/// that only runs at startup cannot catch a device that dies at second two.
///
/// Opt-in (opens the real microphone; audio is discarded):
///   TEST_RUNNER_SEAL_MIC_SMOKE=1
final class MicWatchdogSmokeTests: XCTestCase {

    func testTheWatchdogKeepsWatchingAfterTheMicProvesItself() async throws {
        guard ProcessInfo.processInfo.environment["SEAL_MIC_SMOKE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SEAL_MIC_SMOKE=1 to run (opens the microphone; may prompt for permission)")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("microphone access not granted to the test host")
        }

        let mic = MicCapturer()
        let heard = Heard()
        mic.onSamples = { heard.add($0.count) }
        try mic.start()
        defer { mic.stop() }

        // Well past `judgeSeconds`, where the old watchdog retired for good.
        try await Task.sleep(nanoseconds: 6_000_000_000)

        XCTAssertGreaterThan(heard.samples, 0, "the microphone delivered nothing; can't test supervision of a dead device")
        XCTAssertTrue(mic.isWatching,
                      "the watchdog stopped supervising a working mic — a later dropout would go unnoticed")
    }

    /// A session builds one engine. Anything more is churn, and each rebuild
    /// drops the tap: on 2026-08-04 a self-triggering configuration-change loop
    /// rebuilt the engine 15 times in 2.85 seconds and swallowed the opening
    /// 2.4 seconds of the meeting — the first words, every session.
    ///
    /// Sharpest on a Mac whose default input is Bluetooth, since that is where
    /// the device substitution provokes the notification; elsewhere it still
    /// holds the line against any other rebuild loop.
    func testASessionBuildsExactlyOneEngine() async throws {
        guard ProcessInfo.processInfo.environment["SEAL_MIC_SMOKE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SEAL_MIC_SMOKE=1 to run")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("microphone access not granted to the test host")
        }
        let mic = MicCapturer()
        try mic.start()
        defer { mic.stop() }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertEqual(mic.engineStarts, 1,
                       "the capture engine rebuilt itself \(mic.engineStarts) times with no route change")
    }

    /// The loop itself: configuration changes that our own device substitution
    /// provokes must not rebuild the engine. Driving `handleConfigurationChange`
    /// directly reproduces what the observer did fifteen times in 2.85 seconds,
    /// without needing a Bluetooth default input to provoke it.
    func testConfigurationChangesOnTheSameDeviceDoNotRebuild() throws {
        guard ProcessInfo.processInfo.environment["SEAL_MIC_SMOKE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SEAL_MIC_SMOKE=1 to run")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("microphone access not granted to the test host")
        }
        let mic = MicCapturer()
        try mic.start()
        defer { mic.stop() }
        XCTAssertEqual(mic.engineStarts, 1)
        for _ in 0..<15 { mic.handleConfigurationChange() }
        XCTAssertEqual(mic.engineStarts, 1,
                       "the engine rebuilt on a configuration change that did not change the input device")
    }

    /// Stopping must release the timer, or it outlives the session.
    func testStoppingEndsSupervision() throws {
        guard ProcessInfo.processInfo.environment["SEAL_MIC_SMOKE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SEAL_MIC_SMOKE=1 to run")
        }
        let mic = MicCapturer()
        try? mic.start()
        mic.stop()
        XCTAssertFalse(mic.isWatching, "the watchdog outlived the session")
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
        var samples: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
