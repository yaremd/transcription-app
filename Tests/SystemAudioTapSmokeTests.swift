import XCTest
import AVFoundation
import CoreAudio
@testable import Seal

/// End-to-end smoke test of the Core Audio process-tap capture path: starts
/// the real SystemAudioCapturer, plays a quiet tone through the default
/// output, and verifies (a) the tap delivers audio containing the tone and
/// (b) the *output device is left in peace* — no default-device switches and
/// no sample-rate renegotiation while capturing. (b) is the regression the
/// ScreenCaptureKit path failed: with Bluetooth headphones, starting capture
/// wrecked playback until the headset disconnected.
///
/// Opt-in (plays sound, needs the system-audio permission):
///   TEST_RUNNER_SEAL_TAP_SMOKE=1
final class SystemAudioTapSmokeTests: XCTestCase {

    func testTapCapturesToneWithoutDisturbingTheOutputDevice() async throws {
        guard ProcessInfo.processInfo.environment["SEAL_TAP_SMOKE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SEAL_TAP_SMOKE=1 to run (plays a quiet tone; may prompt for the system-audio permission)")
        }
        guard #available(macOS 14.2, *) else { throw XCTSkip("process tap needs macOS 14.2+") }

        // Baseline: which device is the default output, at what rate.
        let deviceBefore = Self.defaultOutputDevice()
        let rateBefore = deviceBefore.flatMap(Self.nominalRate(of:))

        let capturer = SystemAudioCapturer()
        let collected = Collected()
        capturer.onSamples = { collected.add($0) }
        capturer.onError = { message in collected.errors.append(message); print("tap error: \(message)") }
        capturer.start()

        // Give the tap a moment, then play a soft 440 Hz tone system-wide.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let player = try Self.tonePlayer(seconds: 3.0, volume: 0.12)
        player.play()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        player.stop()
        capturer.stop()

        let deviceAfter = Self.defaultOutputDevice()
        let rateAfter = deviceAfter.flatMap(Self.nominalRate(of:))

        let (chunks, peak) = collected.snapshot()
        print("tap smoke: chunks=\(chunks) peakRMS=\(String(format: "%.4f", peak)) " +
              "device \(deviceBefore ?? 0)→\(deviceAfter ?? 0) rate \(rateBefore ?? 0)→\(rateAfter ?? 0) errors=\(collected.errors)")

        XCTAssertTrue(collected.errors.isEmpty, "capture reported errors: \(collected.errors)")
        XCTAssertGreaterThan(chunks, 10, "the tap delivered almost no audio")
        XCTAssertGreaterThan(peak, 0.005, "the tone never reached the tap — capture is silent")
        XCTAssertEqual(deviceBefore, deviceAfter, "capturing switched the default output device")
        XCTAssertEqual(rateBefore ?? 0, rateAfter ?? 0, accuracy: 0.5,
                       "capturing renegotiated the output device's sample rate")
    }

    /// Thread-safe sample sink (the tap delivers on its own queue).
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var chunkCount = 0
        private var peakRMS: Float = 0
        var errors: [String] = []

        func add(_ samples: [Float]) {
            guard !samples.isEmpty else { return }
            var sum: Float = 0
            for value in samples { sum += value * value }
            let rms = (sum / Float(samples.count)).squareRoot()
            lock.lock()
            chunkCount += 1
            peakRMS = max(peakRMS, rms)
            lock.unlock()
        }

        func snapshot() -> (chunks: Int, peak: Float) {
            lock.lock(); defer { lock.unlock() }
            return (chunkCount, peakRMS)
        }
    }

    private static func tonePlayer(seconds: Double, volume: Float) throws -> AVAudioPlayer {
        let rate = 44_100.0
        let frames = Int(seconds * rate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-tap-smoke-\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = sinf(Float(i) * 2 * .pi * 440 / Float(rate))
        }
        try file.write(from: buffer)
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = volume
        player.prepareToPlay()
        return player
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func nominalRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }
}
