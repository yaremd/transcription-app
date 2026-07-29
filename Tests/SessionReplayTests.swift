import XCTest
import AVFoundation
@testable import Seal

/// Replays a real recorded session (the two .m4a files Seal keeps next to a
/// meeting) through the production TranscriptionStream + Transcriber, printing
/// every decode decision. This is the harness that diagnosed the 2026-07-29
/// "missed almost everything" call, and the bar any fix has to clear.
///
/// Deliberately opt-in: it loads the full Whisper model and decodes minutes of
/// audio, so it only runs when pointed at a session:
///
///   TEST_RUNNER_SEAL_REPLAY_DIR=/path/with/system.m4a+mic.m4a \
///   xcodebuild test -scheme LocalScribe -only-testing:LocalScribeTests/SessionReplayTests ...
///
/// Optional: TEST_RUNNER_SEAL_REPLAY_SECONDS caps how much audio is replayed.
/// Optional: TEST_RUNNER_SEAL_REPLAY_PACE feeds audio at that multiple of
/// real time (1 = live speed) instead of as fast as possible. Pacing is what
/// makes live-preview passes fire on their production cadence, overlapping
/// the final decodes on the shared WhisperKit — the concurrency the fast
/// replay never exercises.
final class SessionReplayTests: XCTestCase {

    /// Collects diagnostics + commits from concurrently-running decode chains.
    private final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var commits: [(source: String, at: TimeInterval, text: String?)] = []
        private var lastEvent = Date()
        private let started = Date()

        func log(_ line: String) {
            lock.lock()
            lines.append(line)
            lastEvent = Date()
            lock.unlock()
        }

        func commit(source: String, at: TimeInterval, text: String?) {
            lock.lock()
            commits.append((source, at, text))
            lastEvent = Date()
            lock.unlock()
        }

        var idleSeconds: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(lastEvent)
        }

        func dump() {
            lock.lock(); defer { lock.unlock() }
            print("========== REPLAY DIAGNOSTICS (\(lines.count) events) ==========")
            for line in lines { print(line) }
            print("========== REPLAY TRANSCRIPT (\(commits.count) commits) ==========")
            for c in commits.sorted(by: { $0.at < $1.at }) {
                let stamp = String(format: "%6.1fs", c.at)
                print("\(stamp) \(c.source): \(c.text ?? "∅ (discarded)")")
            }
            print("========== END REPLAY ==========")
        }
    }

    func testReplayRecordedSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SEAL_REPLAY_DIR"] else {
            throw XCTSkip("Set SEAL_REPLAY_DIR to a folder containing system.m4a and mic.m4a")
        }
        let cap = env["SEAL_REPLAY_SECONDS"].flatMap(Double.init) ?? .infinity
        let base = URL(fileURLWithPath: dir)
        var system = try Self.loadMono16k(base.appendingPathComponent("system.m4a"))
        var mic = try Self.loadMono16k(base.appendingPathComponent("mic.m4a"))
        if cap.isFinite {
            let limit = Int(cap * 16_000)
            system = Array(system.prefix(limit))
            mic = Array(mic.prefix(limit))
        }
        print("replay: system=\(Double(system.count) / 16_000)s mic=\(Double(mic.count) / 16_000)s")

        let journal = Journal()
        let transcriber = Transcriber()
        await transcriber.setDiagnostics { journal.log($0) }
        try await transcriber.load(candidates: TranscriptionSpeed.fast.modelCandidates)
        let model = await transcriber.loadedModel
        print("replay: model=\(model ?? "?")")
        await transcriber.beginSession()
        // The failing session ran with the language picker on Auto.
        await transcriber.setLanguagePolicy(forced: nil, allowed: TranscriptLanguage.auto.allowedCodes)
        await transcriber.setVocabulary([])

        let feedStart = Date()
        func makeStream(_ label: String) -> TranscriptionStream {
            let stream = TranscriptionStream(label: label) { samples, mode in
                await transcriber.transcribe(samples, source: label, mode: mode)
            }
            stream.onCommit = { _, text, timing in
                journal.commit(source: label,
                               at: timing.start.timeIntervalSince(feedStart),
                               text: text)
            }
            return stream
        }
        let systemStream = makeStream("Others")
        let micStream = makeStream("You")

        // Interleave the two feeds on the audio timeline, chunked the way the
        // capturers deliver: ~20 ms buffers from ScreenCaptureKit, ~85 ms from
        // the AVAudioEngine mic tap.
        let pace = env["SEAL_REPLAY_PACE"].flatMap(Double.init) ?? 0
        let sysChunk = 320, micChunk = 1365
        var iSys = 0, iMic = 0
        while iSys < system.count || iMic < mic.count {
            let tSys = Double(iSys) / 16_000, tMic = Double(iMic) / 16_000
            if pace > 0 {
                let target = feedStart.addingTimeInterval(min(tSys, tMic) / pace)
                let wait = target.timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
            if iMic >= mic.count || (iSys < system.count && tSys <= tMic) {
                let end = min(iSys + sysChunk, system.count)
                systemStream.append(Array(system[iSys..<end]))
                iSys = end
            } else {
                let end = min(iMic + micChunk, mic.count)
                micStream.append(Array(mic[iMic..<end]))
                iMic = end
            }
        }
        systemStream.flush()
        micStream.flush()

        // The commit chains drain in the background; wait until they've been
        // quiet for a while (a single final pass can take tens of seconds).
        let deadline = Date().addingTimeInterval(45 * 60)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        while journal.idleSeconds < 90, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        await transcriber.endSession()
        journal.dump()
    }

    /// Decodes an .m4a to 16 kHz mono Float samples (the exact stream the
    /// capture pipeline produced — SessionAudioRecorder wrote it losslessly
    /// apart from AAC).
    private static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
            throw NSError(domain: "replay", code: 1)
        }
        try file.read(into: inBuf)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                      channels: 1, interleaved: false)!
        if inFormat.sampleRate == 16_000, inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32 {
            return Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0],
                                             count: Int(inBuf.frameLength)))
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "replay", code: 2)
        }
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / inFormat.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw NSError(domain: "replay", code: 3)
        }
        var fed = false
        var convertError: NSError?
        converter.convert(to: outBuf, error: &convertError) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let convertError { throw convertError }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0],
                                         count: Int(outBuf.frameLength)))
    }
}
