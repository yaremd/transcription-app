import AVFoundation
import OSLog

/// Errors surfaced to the UI when the microphone can't be started at all.
enum MicError: LocalizedError {
    case permissionDenied
    case noInput

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "macOS is blocking microphone access. Open System Settings → Privacy & Security → Microphone, switch LocalScribe on, then Stop and Start again."
        case .noInput:
            return "no usable microphone input was found."
        }
    }
}

/// Captures the local microphone with AVAudioEngine, resamples to 16 kHz mono
/// Float, and streams the samples out. Triggers the macOS microphone prompt.
///
/// Voice processing (Apple's echo cancellation + noise suppression) is enabled
/// so call audio played through speakers doesn't also land in the transcript
/// as "You". On some Macs/audio routes the voice-processing unit runs but eats
/// the input — sometimes pure digital silence, sometimes low-level junk with
/// the speech removed — so a fixed loudness threshold can't tell "broken" from
/// "quiet room". Instead, while voice processing is unverified, a second plain
/// engine taps the same microphone as a *witness*: if the witness hears real
/// sound and the processed path stays ~20× quieter, voice processing is
/// provably eating audio and capture restarts on the raw mic. If even the raw
/// path delivers nothing, the user is told exactly which System Settings to
/// check instead of watching a dead meter.
final class MicCapturer {
    var onSamples: (([Float]) -> Void)?
    /// Non-fatal condition worth a status-line mention (e.g. AEC fallback).
    var onNotice: ((String) -> Void)?
    /// No audio is arriving and the capturer couldn't fix it by itself.
    var onError: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var referenceEngine: AVAudioEngine?
    private var resampler = AudioResampler()
    private var configObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.yarem.LocalScribe", category: "Mic")

    /// Cleared for the rest of the app run once voice processing is caught
    /// eating the input; later sessions then start on the raw mic at once.
    private var voiceProcessingTrusted = true
    private var voiceProcessingActive = false
    private var sessionActive = false
    private var referenceRunning = false

    // Written from the audio threads, read by the watchdog on the main thread.
    private let meterLock = NSLock()
    private var tapPeak: Float = 0          // loudest sample the processed tap saw
    private var referencePeak: Float = 0    // loudest sample the raw witness saw
    private var samplesDelivered = false    // resampled audio actually left the tap

    private var watchdog: Timer?
    private var watchdogStart = Date()

    /// The witness heard something clearly real (speech, typing, room life).
    private let rawSpeechPeak: Float = 5e-3
    /// Processed path this many times quieter than the witness = eaten audio.
    private let mutedRatio: Float = 20
    /// Processed path at least this loud = clearly passing audio.
    private let alivePeak: Float = 1e-3
    /// Below this on every path = the device itself is delivering nothing.
    private let deadPeak: Float = 1e-4
    private let minJudgeSeconds = 3.0
    private let deadDeviceSeconds = 15.0
    /// Without a witness, silence this long decides on its own.
    private let heuristicSeconds = 3.5

    func start() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            throw MicError.permissionDenied
        }
        sessionActive = true
        try startEngine()
    }

    func stop() {
        sessionActive = false
        stopReference()
        tearDownEngine()
    }

    // MARK: - Engine lifecycle

    /// Builds a fresh engine each time: voice-processing state doesn't survive
    /// start/stop cycles reliably, and a fallback restart must not inherit a
    /// converter or tap sized for the previous device format.
    private func startEngine() throws {
        stopReference()
        tearDownEngine()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Voice processing = Apple's echo cancellation + noise suppression.
        // Without it, call audio played through speakers bleeds into the mic
        // and every phrase lands twice: once as "You", once as "Others".
        // Ducking is disabled so the call we're also capturing isn't quieted.
        // If enabling fails (exotic audio devices), fall back to the raw mic.
        if input.isVoiceProcessingEnabled != voiceProcessingTrusted {
            do { try input.setVoiceProcessingEnabled(voiceProcessingTrusted) } catch {
                log.warning("setVoiceProcessingEnabled failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        voiceProcessingActive = input.isVoiceProcessingEnabled
        if voiceProcessingActive {
            input.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            // The input node is in a broken state; voice processing is the
            // usual culprit. Retry once on the raw mic before giving up.
            if voiceProcessingActive && voiceProcessingTrusted {
                voiceProcessingTrusted = false
                log.error("invalid input format with voice processing on; retrying raw")
                try startEngine()
                return
            }
            throw MicError.noInput
        }

        meterLock.lock()
        tapPeak = 0
        referencePeak = 0
        samplesDelivered = false
        meterLock.unlock()

        // The tap captures this resampler instance directly so a restart can
        // swap in a fresh one without racing the audio thread.
        let resampler = AudioResampler()
        self.resampler = resampler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.notePeak(of: buffer, into: \.tapPeak)
            guard let samples = resampler.resample(buffer) else { return }
            self.meterLock.lock()
            self.samplesDelivered = true
            self.meterLock.unlock()
            self.onSamples?(samples)
        }
        engine.prepare()
        try engine.start()

        // Only an unverified voice-processing path needs the raw witness.
        if voiceProcessingActive {
            startReference()
        }
        log.notice("mic starting: vp=\(self.voiceProcessingActive) witness=\(self.referenceRunning) format=\(format.sampleRate, format: .fixed(precision: 0))Hz x\(format.channelCount)ch")

        // The input node follows the system default device. When that changes
        // (AirPods connect, an interface unplugs) the engine stops delivering;
        // rebuild on the new device and let the watchdog re-verify it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.sessionActive else { return }
            self.log.notice("audio route changed; restarting capture")
            do { try self.startEngine() } catch {
                self.onError?("The microphone stopped after an audio device change: \(error.localizedDescription)")
            }
        }

        armWatchdog()
    }

    private func tearDownEngine() {
        watchdog?.invalidate()
        watchdog = nil
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        self.engine = nil
    }

    /// A second, plain engine on the same microphone. It exists only to answer
    /// "is there actually sound in the room?" while voice processing is judged,
    /// and is torn down the moment a verdict lands.
    private func startReference() {
        stopReference()
        let reference = AVAudioEngine()
        let input = reference.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.notePeak(of: buffer, into: \.referencePeak)
        }
        reference.prepare()
        do {
            try reference.start()
            referenceEngine = reference
            referenceRunning = true
        } catch {
            input.removeTap(onBus: 0)
            referenceRunning = false
            log.warning("witness engine unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopReference() {
        guard let reference = referenceEngine else { referenceRunning = false; return }
        reference.inputNode.removeTap(onBus: 0)
        if reference.isRunning { reference.stop() }
        referenceEngine = nil
        referenceRunning = false
    }

    // MARK: - Silence watchdog

    private func notePeak(of buffer: AVAudioPCMBuffer, into key: ReferenceWritableKeyPath<MicCapturer, Float>) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var peak: Float = 0
        let samples = data[0]
        for i in 0..<Int(buffer.frameLength) {
            let v = abs(samples[i])
            if v > peak { peak = v }
        }
        meterLock.lock()
        if peak > self[keyPath: key] { self[keyPath: key] = peak }
        meterLock.unlock()
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        watchdogStart = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.judge()
        }
    }

    private func disarmWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        stopReference()
    }

    private func judge() {
        guard sessionActive else {
            disarmWatchdog()
            return
        }

        // While the first-run permission prompt is up the device delivers
        // zeros; that's not evidence against voice processing. Keep waiting.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            watchdogStart = Date()
            return
        }

        meterLock.lock()
        let processed = tapPeak
        let raw = referencePeak
        let delivered = samplesDelivered
        meterLock.unlock()
        let elapsed = Date().timeIntervalSince(watchdogStart)

        // The device is audible but nothing ever left the tap: the resampler
        // can't handle this format. A restart rebuilds it; without voice
        // processing the format is the plain device one, which always converts.
        if elapsed >= minJudgeSeconds && !delivered && processed >= alivePeak {
            log.error("pipeline dead: tap peak \(processed, format: .fixed(precision: 5)) but no samples delivered")
            restartWithoutVoiceProcessing(reason: "the audio pipeline stalled")
            return
        }

        if voiceProcessingActive {
            if referenceRunning {
                if delivered && processed >= max(alivePeak, raw / mutedRatio) {
                    log.notice("voice processing verified: processed \(processed, format: .fixed(precision: 5)) raw \(raw, format: .fixed(precision: 5))")
                    disarmWatchdog()
                } else if elapsed >= minJudgeSeconds && raw >= rawSpeechPeak && processed < raw / mutedRatio {
                    log.error("voice processing eating audio: processed \(processed, format: .fixed(precision: 5)) vs raw \(raw, format: .fixed(precision: 5))")
                    restartWithoutVoiceProcessing(reason: "echo cancellation was blocking your mic")
                } else if elapsed >= deadDeviceSeconds && raw < deadPeak && processed < deadPeak {
                    log.error("no signal on any path: raw \(raw, format: .fixed(precision: 6))")
                    disarmWatchdog()
                    reportDeadInput()
                }
                // Otherwise the room is still quiet — keep the witness running
                // until someone speaks; only sound can prove either verdict.
            } else {
                // No witness available: fall back to a plain loudness deadline.
                if delivered && processed >= alivePeak {
                    disarmWatchdog()
                } else if elapsed >= heuristicSeconds {
                    log.error("voice processing silent past deadline (no witness): peak \(processed, format: .fixed(precision: 5))")
                    restartWithoutVoiceProcessing(reason: "echo cancellation was blocking your mic")
                }
            }
        } else {
            // Raw path: any real noise floor at all counts as alive.
            if delivered && processed >= deadPeak {
                disarmWatchdog()
            } else if elapsed >= heuristicSeconds {
                log.error("raw mic delivered nothing: peak \(processed, format: .fixed(precision: 6))")
                disarmWatchdog()
                reportDeadInput()
            }
        }
    }

    private func restartWithoutVoiceProcessing(reason: String) {
        voiceProcessingTrusted = false
        do {
            try startEngine()
            onNotice?("Note: \(reason) — switched to the raw microphone. Listening. (If the call plays through speakers, headphones avoid echo.)")
        } catch {
            onError?("The microphone couldn't be restarted: \(error.localizedDescription)")
        }
    }

    private func reportDeadInput() {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            onError?(MicError.permissionDenied.errorDescription ?? "Microphone access is blocked.")
        } else {
            onError?("No sound is reaching the app from the microphone. Check System Settings → Sound → Input: the right microphone should be selected and its input volume up.")
        }
    }
}
