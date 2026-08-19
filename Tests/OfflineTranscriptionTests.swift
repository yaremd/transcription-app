import XCTest
import AVFoundation
import WhisperKit
@testable import Seal

/// The claim the privacy page dares people to check: "on a plane, in a SCIF,
/// or with the Wi-Fi switched off as a test."
///
/// `OfflineModelLoadTests` proves the *load* never reaches for the network, by
/// pointing the endpoint at a closed port. That is a strong test of one step.
/// This is the whole claim end to end — a real saved recording, through the
/// production `WhisperModelStore` path, into actual words — and it is meant to
/// be run with the machine genuinely disconnected, where "no route to host" is
/// the operating system's answer rather than a test fixture's.
///
/// It transcribes the user's own audio, because that is the only real speech
/// on the machine. Nothing it produces is printed: the assertions are about
/// how much text came back, never what it said.
final class OfflineTranscriptionTests: XCTestCase {

    /// The *loudest* saved recording, not the shortest. Picking by file size
    /// chose a near-silent one first time round and Whisper correctly returned
    /// nothing — a green-looking failure that proved only that silence is
    /// silent. Signal level is what makes this a test of transcription.
    private func loudestRecording() throws -> URL {
        let meetings = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Seal/Meetings", isDirectory: true)
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: meetings, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url -> (URL, Int)? in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 200_000, size < 3_000_000 else { return nil }
                return (url, size)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(12)
            .map(\.0)

        var best: (url: URL, rms: Float)?
        for url in candidates {
            guard let audio = try? samples(of: url, seconds: 10), !audio.isEmpty else { continue }
            let rms = (audio.reduce(0) { $0 + $1 * $1 } / Float(audio.count)).squareRoot()
            if rms > (best?.rms ?? 0) { best = (url, rms) }
        }
        guard let best, best.rms > 0.01 else {
            throw XCTSkip("no saved recording with enough signal to transcribe")
        }
        print("OFFLINE-TEST: chose a recording with rms \(String(format: "%.4f", best.rms))")
        return best.url
    }

    private func samples(of url: URL, seconds: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let wanted = AVAudioFrameCount(min(Double(file.length), format.sampleRate * seconds))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted))
        try file.read(into: buffer, frameCount: wanted)
        if format.sampleRate == 16_000, format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return try XCTUnwrap(AudioResampler().resample(buffer))
    }

    func testRealRecordingTranscribesWithNoNetwork() async throws {
        let recording = try loudestRecording()
        let audio = try samples(of: recording, seconds: 30)
        XCTAssertGreaterThan(audio.count, 16_000, "need at least a second of audio to be a real test")

        // Exactly what the app does, including the model choice a recording makes.
        let transcriber = Transcriber()
        try await transcriber.load(candidates: TranscriptionSpeed.fast.modelCandidates)
        let loaded = await transcriber.loadedModel
        print("OFFLINE-TEST: loaded model = \(loaded ?? "none")")

        await transcriber.beginSession()
        await transcriber.setLanguagePolicy(forced: nil, allowed: ["en", "uk"])
        let text = await transcriber.transcribe(audio, source: "You", mode: .final)
        await transcriber.endSession()

        // The content is the user's own meeting and is never printed.
        print("OFFLINE-TEST: transcribed \(text.count) characters from \(audio.count) samples")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "a cached model must turn real speech into text with no network at all")
    }
}
