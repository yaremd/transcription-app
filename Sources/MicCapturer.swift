import AVFoundation
import OSLog

/// Errors surfaced to the UI when the microphone can't be started at all.
enum MicError: LocalizedError {
    case permissionDenied
    case noInput

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "macOS is blocking microphone access. Open System Settings → Privacy & Security → Microphone, switch Seal on, then Stop and Start again."
        case .noInput:
            return "no usable microphone input was found."
        }
    }
}

/// Captures the local microphone with AVAudioEngine, resamples to 16 kHz mono
/// Float, and streams the samples out. Triggers the macOS microphone prompt.
///
/// Deliberately captures the RAW microphone — Apple's voice processing (echo
/// cancellation) is never enabled. On this hardware the voice-processed input
/// removes the speech itself and delivers sub-audible junk in its place; it
/// defeated every liveness check tried against it (fixed thresholds, a raw
/// witness engine, peak-ratio comparison — see 2026-07-23 history). Call audio
/// bleeding from the speakers into the mic is handled downstream instead:
/// AudioMonitor drops "You" lines that duplicate a recent "Others" line.
///
/// A short watchdog still guards the raw path: if nothing audible arrives at
/// all, the user is told exactly which System Settings to check instead of
/// watching a dead meter.
final class MicCapturer {
    var onSamples: (([Float]) -> Void)?
    /// Non-fatal condition worth a status-line mention.
    var onNotice: ((String) -> Void)?
    /// No audio is arriving and the capturer couldn't fix it by itself.
    var onError: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var resampler = AudioResampler()
    private var configObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.yarem.Seal", category: "Mic")
    private var sessionActive = false

    // Written from the audio thread, read by the watchdog on the main thread.
    private let meterLock = NSLock()
    private var tapPeak: Float = 0          // loudest sample the tap saw
    private var samplesDelivered = false    // resampled audio actually left the tap

    private var watchdog: Timer?
    private var watchdogStart = Date()

    /// A live mic always has at least this much noise floor; below it for the
    /// whole window means the device is delivering nothing.
    private let deadPeak: Float = 1e-4
    private let judgeSeconds = 3.5

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

    /// Builds a fresh engine each time, so no state (taps, converters,
    /// lingering voice-processing flags) survives between sessions or devices.
    private func startEngine() throws {
        tearDownEngine()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Defensive: voice-processing state can linger process-wide. Make sure
        // this input is the raw device path.
        if input.isVoiceProcessingEnabled {
            do { try input.setVoiceProcessingEnabled(false) } catch {
                log.warning("couldn't disable voice processing: \(error.localizedDescription, privacy: .public)")
            }
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicError.noInput
        }
        log.notice("mic starting raw: format=\(format.sampleRate, format: .fixed(precision: 0))Hz x\(format.channelCount)ch")

        meterLock.lock()
        tapPeak = 0
        samplesDelivered = false
        meterLock.unlock()

        // The tap captures this resampler instance directly so a restart can
        // swap in a fresh one without racing the audio thread.
        let resampler = AudioResampler()
        self.resampler = resampler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.notePeak(of: buffer)
            guard let samples = resampler.resample(buffer) else { return }
            self.meterLock.lock()
            self.samplesDelivered = true
            self.meterLock.unlock()
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
        if peak > tapPeak { tapPeak = peak }
        meterLock.unlock()
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        watchdogStart = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.judge()
        }
    }

    private func judge() {
        guard sessionActive else {
            watchdog?.invalidate()
            watchdog = nil
            return
        }

        // While the first-run permission prompt is up the device delivers
        // zeros; wait for the user's answer before judging.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            watchdogStart = Date()
            return
        }

        meterLock.lock()
        let peak = tapPeak
        let delivered = samplesDelivered
        meterLock.unlock()

        if delivered && peak >= deadPeak {
            // Audible and flowing; nothing left to watch this session.
            watchdog?.invalidate()
            watchdog = nil
            return
        }
        guard Date().timeIntervalSince(watchdogStart) >= judgeSeconds else { return }

        watchdog?.invalidate()
        watchdog = nil
        if !delivered && peak >= deadPeak {
            // Device is audible but conversion produced nothing — resampler
            // trouble; details are in the Resampler log.
            log.error("pipeline dead: tap peak \(peak, format: .fixed(precision: 5)) but no samples delivered")
            onError?("The microphone is live but its audio couldn't be processed. Stop and Start again; if it persists, tell the developer to check the Resampler log.")
        } else {
            log.error("raw mic delivered nothing: peak \(peak, format: .fixed(precision: 6))")
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                onError?(MicError.permissionDenied.errorDescription ?? "Microphone access is blocked.")
            } else {
                onError?("No sound is reaching the app from the microphone. Check System Settings → Sound → Input: the right microphone should be selected and its input volume up.")
            }
        }
    }
}
