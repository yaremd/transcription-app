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
/// as "You". On some Macs/audio routes the voice-processing unit initializes
/// fine but delivers pure digital silence — the app looks deaf while the call
/// side keeps transcribing. A watchdog therefore checks the first seconds of
/// every session: if only silence arrived, capture restarts on the raw mic
/// (the path that always works); if even that is silent, the user is told
/// exactly which System Settings to check instead of watching a dead meter.
final class MicCapturer {
    var onSamples: (([Float]) -> Void)?
    /// Non-fatal condition worth a status-line mention (e.g. AEC fallback).
    var onNotice: ((String) -> Void)?
    /// No audio is arriving and the capturer couldn't fix it by itself.
    var onError: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var resampler = AudioResampler()
    private var configObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.yarem.LocalScribe", category: "Mic")

    /// Cleared for the rest of the app run once voice processing is caught
    /// silencing the input; later sessions then start on the raw mic at once.
    private var voiceProcessingTrusted = true
    private var voiceProcessingActive = false
    private var sessionActive = false

    // Written from the audio thread, read by the watchdog on the main thread.
    private let meterLock = NSLock()
    private var peakSinceStart: Float = 0

    private var watchdog: Timer?
    private var watchdogStart = Date()

    /// Anything below this for the whole watchdog window is digital silence,
    /// not a quiet room — a live mic always delivers some noise floor.
    private let silencePeak: Float = 1e-4
    private let watchdogWindow = 2.5

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
        tearDownEngine()
    }

    // MARK: - Engine lifecycle

    /// Builds a fresh engine each time: voice-processing state doesn't survive
    /// start/stop cycles reliably, and a fallback restart must not inherit a
    /// converter or tap sized for the previous device format.
    private func startEngine() throws {
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
        log.info("mic starting: vp=\(self.voiceProcessingActive) format=\(format.sampleRate)Hz x\(format.channelCount)ch")

        meterLock.lock()
        peakSinceStart = 0
        meterLock.unlock()

        // The tap captures this resampler instance directly so a restart can
        // swap in a fresh one without racing the audio thread.
        let resampler = AudioResampler()
        self.resampler = resampler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.notePeak(of: buffer)
            guard let samples = resampler.resample(buffer) else { return }
            self.onSamples?(samples)
        }
        engine.prepare()
        try engine.start()

        // The input node follows the system default device. When that changes
        // (AirPods connect, an interface unplugs) the engine stops delivering;
        // rebuild on the new device and let the watchdog re-verify it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.sessionActive else { return }
            self.log.info("audio route changed; restarting capture")
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

    // MARK: - Silence watchdog

    private func notePeak(of buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var peak: Float = 0
        let samples = data[0]
        for i in 0..<Int(buffer.frameLength) {
            let v = abs(samples[i])
            if v > peak { peak = v }
        }
        meterLock.lock()
        if peak > peakSinceStart { peakSinceStart = peak }
        meterLock.unlock()
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        watchdogStart = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForSilence()
        }
    }

    private func checkForSilence() {
        guard sessionActive else {
            watchdog?.invalidate()
            watchdog = nil
            return
        }

        // While the first-run permission prompt is up the device delivers
        // zeros; that's not evidence against voice processing. Keep waiting.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            watchdogStart = Date()
            return
        }

        meterLock.lock()
        let peak = peakSinceStart
        meterLock.unlock()

        if peak >= silencePeak {
            // The mic is audibly alive; nothing left to watch this session.
            watchdog?.invalidate()
            watchdog = nil
            return
        }
        guard Date().timeIntervalSince(watchdogStart) >= watchdogWindow else { return }

        if voiceProcessingActive {
            // Echo cancellation delivered nothing but digital silence — the
            // known macOS failure this watchdog exists for.
            log.error("voice processing delivered only silence; falling back to raw mic")
            voiceProcessingTrusted = false
            do {
                try startEngine()
                onNotice?("Echo cancellation was blocking your mic — turned it off. Listening on the raw microphone now; if the call plays through speakers, headphones will avoid echo.")
            } catch {
                onError?("The microphone couldn't be restarted: \(error.localizedDescription)")
            }
        } else {
            watchdog?.invalidate()
            watchdog = nil
            log.error("raw mic delivered only silence")
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                onError?(MicError.permissionDenied.errorDescription ?? "Microphone access is blocked.")
            } else {
                onError?("No sound is reaching the app from the microphone. Check System Settings → Sound → Input: the right microphone should be selected and its input volume up.")
            }
        }
    }
}
