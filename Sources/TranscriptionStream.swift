import Foundation

/// Buffers 16 kHz mono samples for one audio source and turns them into text.
/// While the speaker talks it emits an updated "live" line; after a short pause
/// (or when the buffer gets long) it "commits" the finished utterance as a final
/// line and starts fresh.
///
/// Crucially, a chunk is only ever sent to Whisper if it contains enough actual
/// *voiced* audio (energy above a speech threshold). Whisper hallucinates stock
/// phrases ("Дякую!", "Thank you") when fed silence, so silent gaps are detected
/// and discarded without transcription.
final class TranscriptionStream {
    var onLive: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    private let label: String
    private let transcriber: Transcriber
    private let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var buffer: [Float] = []
    private var silenceSeconds = 0.0
    private var voicedSeconds = 0.0

    private var lastTranscribe = Date.distantPast
    private var isTranscribing = false

    private let silenceThreshold: Float = 0.006   // below this = a pause (for segmentation)
    private let speechThreshold: Float = 0.015    // above this = real voiced speech
    private let minVoicedSeconds = 0.3            // need this much speech to transcribe at all
    private let commitSilence = 1.0               // seconds of quiet -> finalize utterance
    private let minTranscribeInterval = 0.5       // throttle live transcriptions (lower = snappier live text)
    private let minAudioSeconds = 0.4
    private let maxUtterance = 18.0

    init(label: String, transcriber: Transcriber) {
        self.label = label
        self.transcriber = transcriber
    }

    func append(_ samples: [Float]) {
        let chunkSeconds = Double(samples.count) / sampleRate
        let energy = rms(of: samples)

        lock.lock()
        buffer.append(contentsOf: samples)
        if energy < silenceThreshold { silenceSeconds += chunkSeconds } else { silenceSeconds = 0 }
        if energy >= speechThreshold { voicedSeconds += chunkSeconds }
        let bufferSeconds = Double(buffer.count) / sampleRate
        let voiced = voicedSeconds
        lock.unlock()

        let now = Date()
        guard bufferSeconds > minAudioSeconds else { return }

        let quietEnough = silenceSeconds >= commitSilence
        let tooLong = bufferSeconds >= maxUtterance

        if quietEnough || tooLong {
            let hasSpeech = voiced >= minVoicedSeconds
            commit(transcribe: hasSpeech)
        } else if voiced >= minVoicedSeconds
                    && now.timeIntervalSince(lastTranscribe) >= minTranscribeInterval
                    && !isTranscribing {
            lastTranscribe = now
            runLive()
        }
    }

    func flush() {
        let (bufferSeconds, voiced): (Double, Double) = {
            lock.lock(); defer { lock.unlock() }
            return (Double(buffer.count) / sampleRate, voicedSeconds)
        }()
        if bufferSeconds > minAudioSeconds {
            commit(transcribe: voiced >= minVoicedSeconds)
        }
    }

    private func runLive() {
        isTranscribing = true
        let audio = snapshot()
        Task {
            let text = await transcriber.transcribe(audio)
            if !text.isEmpty { onLive?(text) }
            isTranscribing = false
        }
    }

    /// Finalizes the current buffer. Always clears it; only transcribes when
    /// `shouldTranscribe` (i.e. the buffer held real speech).
    private func commit(transcribe shouldTranscribe: Bool) {
        let audio = snapshot()
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        silenceSeconds = 0
        voicedSeconds = 0
        lock.unlock()

        guard shouldTranscribe else { return }
        Task {
            let text = await transcriber.transcribe(audio)
            if !text.isEmpty { onCommit?(text) }
        }
    }

    private func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    private func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return (sum / Float(samples.count)).squareRoot()
    }
}
