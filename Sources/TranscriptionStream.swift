import Foundation

/// Which kind of pass a transcription request is. Live passes favor speed,
/// final passes favor accuracy.
enum TranscribeMode {
    case live
    case final
}

/// Buffers 16 kHz mono samples for one audio source, segments them into
/// utterances, and turns them into text.
///
/// While the speaker talks it emits an updated "live" line; after a short pause
/// (or when the utterance grows too long) it "commits" the utterance as a final
/// line and starts fresh. Every utterance carries an id: live results are
/// tagged with it, and a live result that arrives after its utterance was
/// already committed is dropped instead of ghosting stale text over the UI.
///
/// Silence is never transcribed — Whisper hallucinates stock phrases ("Дякую!",
/// "Thank you") when fed quiet audio. The speech threshold adapts to the
/// ambient noise floor with hysteresis, so quiet speakers still register while
/// steady fan/room noise does not, and the audio sent to Whisper is trimmed to
/// the voiced span.
final class TranscriptionStream {
    /// (utteranceID, text) — updated preview of the utterance still being spoken.
    var onLive: ((Int, String) -> Void)?
    /// (utteranceID, text) — utterance finished. nil text = discarded as silence.
    var onCommit: ((Int, String?) -> Void)?

    private let label: String
    private let transcribe: ([Float], TranscribeMode) async -> String
    private let sampleRate = 16_000.0

    /// One capture callback's worth of audio, with its measured loudness.
    private struct Frame {
        let sampleCount: Int
        let energy: Float
    }

    private let lock = NSLock()
    private var buffer: [Float] = []
    private var frames: [Frame] = []
    private var inSpeech = false
    private var silenceRun = 0.0        // seconds since the last voiced frame
    private var voicedSeconds = 0.0
    private var noiseFloor: Float = 0.002
    private var utterance = 0           // id of the utterance currently in the buffer
    private var liveInFlight = false
    private var commitBusy = false
    private var lastLiveStart = Date.distantPast
    private var lastLiveDuration = 0.0
    private var commitChain: Task<Void, Never>?

    private let commitSilence = 0.85        // quiet gap that ends an utterance
    private let minVoicedSeconds = 0.3      // speech needed before transcribing at all
    private let baseLiveInterval = 0.45     // fastest live-update cadence
    private let maxUtteranceSeconds = 18.0  // hard cap before a forced split
    private let idleTrimSeconds = 8.0       // no speech for this long -> shed old audio
    private let preRollSeconds = 1.2        // context kept ahead of a speech onset
    private let trimPadSeconds = 0.3        // padding kept around the voiced span

    init(label: String, transcribe: @escaping ([Float], TranscribeMode) async -> String) {
        self.label = label
        self.transcribe = transcribe
    }

    // The floor tracks ambient loudness; speech must clear it with margin.
    // Hysteresis: once talking, audio only needs to stay above the lower "off"
    // threshold, so soft word endings aren't chopped into separate utterances.
    private var speechOnThreshold: Float { min(max(noiseFloor * 3.0, 0.006), 0.025) }
    private var speechOffThreshold: Float { max(speechOnThreshold * 0.5, 0.004) }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let energy = Self.rms(of: samples)
        let seconds = Double(samples.count) / sampleRate

        enum Action { case none, commit, forceCut, idleTrim, live }

        lock.lock()
        buffer.append(contentsOf: samples)
        frames.append(Frame(sampleCount: samples.count, energy: energy))

        let on = speechOnThreshold
        if energy < on {
            // Ambient floor: falls quickly when the room gets quieter, rises
            // slowly so speech onsets don't drag it up.
            let alpha = Float(min(1.0, seconds / (energy < noiseFloor ? 0.6 : 4.0)))
            noiseFloor += alpha * (energy - noiseFloor)
        }

        if energy >= on || (inSpeech && energy >= speechOffThreshold) {
            inSpeech = true
            voicedSeconds += seconds
            silenceRun = 0
        } else {
            silenceRun += seconds
        }

        let bufferSeconds = Double(buffer.count) / sampleRate
        var action = Action.none
        if inSpeech && silenceRun >= commitSilence {
            action = .commit
        } else if bufferSeconds >= maxUtteranceSeconds {
            action = inSpeech ? .forceCut : .idleTrim
        } else if !inSpeech && bufferSeconds >= idleTrimSeconds {
            action = .idleTrim
        } else if inSpeech && voicedSeconds >= minVoicedSeconds && canStartLiveLocked() {
            action = .live
            liveInFlight = true
            lastLiveStart = Date()
        }
        lock.unlock()

        switch action {
        case .commit: commitCurrent()
        case .forceCut: forceCut()
        case .idleTrim: trimIdle()
        case .live: runLive()
        case .none: break
        }
    }

    /// Finalizes whatever is buffered (used on Stop/Pause).
    func flush() {
        commitCurrent()
    }

    // MARK: - Live pass

    /// A live pass may start only when the previous one finished, no final pass
    /// is hogging the model, and enough time passed. The cadence adapts to how
    /// long transcription actually takes, so a slow model never builds a backlog.
    private func canStartLiveLocked() -> Bool {
        guard !liveInFlight && !commitBusy else { return false }
        let interval = max(baseLiveInterval, min(lastLiveDuration * 1.3, 3.0))
        return Date().timeIntervalSince(lastLiveStart) >= interval
    }

    private func runLive() {
        lock.lock()
        let id = utterance
        let audio = trimmedUtteranceLocked()
        lock.unlock()

        Task(priority: .userInitiated) {
            let started = Date()
            let text = audio.isEmpty ? "" : await self.transcribe(audio, .live)
            let stale = self.finishLive(started: started, id: id)
            if !stale && !text.isEmpty { self.onLive?(id, text) }
        }
    }

    /// Records the live pass duration (for cadence) and reports whether its
    /// utterance was already committed while transcription ran.
    private func finishLive(started: Date, id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastLiveDuration = Date().timeIntervalSince(started)
        liveInFlight = false
        return id != utterance
    }

    // MARK: - Commit

    private func commitCurrent() {
        lock.lock()
        guard !buffer.isEmpty else { lock.unlock(); return }
        let id = utterance
        let audio = voicedSeconds >= minVoicedSeconds ? trimmedUtteranceLocked() : []
        resetUtteranceLocked()
        enqueueCommitLocked(id: id, audio: audio)
        lock.unlock()
    }

    /// Commits run on a chain so final lines always append in speaking order,
    /// even when a short utterance transcribes faster than the long one before it.
    private func enqueueCommitLocked(id: Int, audio: [Float]) {
        let previous = commitChain
        commitChain = Task(priority: .userInitiated) {
            await previous?.value
            var text: String?
            if !audio.isEmpty {
                self.setCommitBusy(true)
                let out = await self.transcribe(audio, .final)
                self.setCommitBusy(false)
                text = out.isEmpty ? nil : out
            }
            self.onCommit?(id, text)
        }
    }

    private func setCommitBusy(_ busy: Bool) {
        lock.lock()
        commitBusy = busy
        lock.unlock()
    }

    private func resetUtteranceLocked() {
        buffer.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        inSpeech = false
        silenceRun = 0
        voicedSeconds = 0
        utterance += 1
    }

    // MARK: - Long-utterance split

    /// The buffer hit its cap mid-speech. Split at the quietest recent moment —
    /// not at an arbitrary sample — so no word is cut in half: the head becomes
    /// a committed line, the tail keeps rolling as the current utterance.
    private func forceCut() {
        lock.lock()
        guard frames.count > 1 else { lock.unlock(); return }
        let off = speechOffThreshold

        // Search the last ~6s (excluding the very end) for the latest quiet
        // frame; fall back to the overall quietest frame in that window.
        let bufferSeconds = Double(buffer.count) / sampleRate
        let windowStart = bufferSeconds - 6.0
        let windowEnd = bufferSeconds - 0.2
        var elapsed = 0.0
        var candidate: Int?          // last frame under the "off" threshold
        var quietest: (index: Int, energy: Float)?
        for (i, frame) in frames.enumerated() {
            let frameStart = elapsed
            elapsed += Double(frame.sampleCount) / sampleRate
            guard frameStart >= windowStart, elapsed <= windowEnd else { continue }
            if frame.energy < off { candidate = i }
            if quietest == nil || frame.energy < quietest!.energy {
                quietest = (i, frame.energy)
            }
        }
        let cutFrame = candidate ?? quietest?.index ?? frames.count / 2

        let headFrames = Array(frames[..<cutFrame])
        let tailFrames = Array(frames[cutFrame...])
        let cutSample = headFrames.reduce(0) { $0 + $1.sampleCount }
        let headBuffer = Array(buffer[..<cutSample])
        let tailBuffer = Array(buffer[cutSample...])

        let id = utterance
        let headVoiced = Self.approxVoiced(headFrames, threshold: off, sampleRate: sampleRate)
        let headAudio = headVoiced >= minVoicedSeconds
            ? Self.trimmed(buffer: headBuffer, frames: headFrames, threshold: off,
                           padSamples: Int(trimPadSeconds * sampleRate))
            : []

        buffer = tailBuffer
        frames = tailFrames
        voicedSeconds = Self.approxVoiced(tailFrames, threshold: off, sampleRate: sampleRate)
        inSpeech = tailFrames.last.map { $0.energy >= off } ?? false
        silenceRun = Self.trailingSilence(tailFrames, threshold: off, sampleRate: sampleRate)
        utterance += 1
        enqueueCommitLocked(id: id, audio: headAudio)
        lock.unlock()
    }

    /// Nothing but noise for a while: shed old audio, keeping a short pre-roll
    /// so a speech onset right after still has context. No events emitted.
    private func trimIdle() {
        lock.lock()
        let keepSamples = Int(preRollSeconds * sampleRate)
        var dropSamples = buffer.count - keepSamples
        if dropSamples > 0 {
            var dropFrames = 0
            var dropped = 0
            for frame in frames {
                guard dropped + frame.sampleCount <= dropSamples else { break }
                dropped += frame.sampleCount
                dropFrames += 1
            }
            dropSamples = dropped
            buffer.removeFirst(dropSamples)
            frames.removeFirst(dropFrames)
            voicedSeconds = 0
        }
        lock.unlock()
    }

    // MARK: - Trimming helpers

    /// The buffered utterance cut down to its voiced span plus padding — Whisper
    /// gets less silence to chew on (faster, fewer hallucinations).
    private func trimmedUtteranceLocked() -> [Float] {
        Self.trimmed(buffer: buffer, frames: frames, threshold: speechOffThreshold,
                     padSamples: Int(trimPadSeconds * sampleRate))
    }

    private static func trimmed(buffer: [Float], frames: [Frame], threshold: Float, padSamples: Int) -> [Float] {
        var firstVoiced: Int?
        var lastVoicedEnd: Int?
        var offset = 0
        for frame in frames {
            if frame.energy >= threshold {
                if firstVoiced == nil { firstVoiced = offset }
                lastVoicedEnd = offset + frame.sampleCount
            }
            offset += frame.sampleCount
        }
        guard let first = firstVoiced, let lastEnd = lastVoicedEnd else { return buffer }
        let start = max(0, first - padSamples)
        let end = min(buffer.count, lastEnd + padSamples)
        return Array(buffer[start..<end])
    }

    private static func approxVoiced(_ frames: [Frame], threshold: Float, sampleRate: Double) -> Double {
        frames.reduce(0.0) { $1.energy >= threshold ? $0 + Double($1.sampleCount) / sampleRate : $0 }
    }

    private static func trailingSilence(_ frames: [Frame], threshold: Float, sampleRate: Double) -> Double {
        var run = 0.0
        for frame in frames.reversed() {
            if frame.energy >= threshold { break }
            run += Double(frame.sampleCount) / sampleRate
        }
        return run
    }

    private static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return (sum / Float(samples.count)).squareRoot()
    }
}
