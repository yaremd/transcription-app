import AVFoundation
import CoreAudio
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

    /// Whether to substitute a wired mic when the default input is Bluetooth.
    /// Cleared for the rest of the session once the substitute turns out not to
    /// be hearing anyone — see `fallBackToDefaultInput`.
    private var avoidBluetoothInput = true
    /// True while capture is running on a device the user did not choose.
    /// Only then is it our business to second-guess what the mic is hearing.
    private(set) var substitutedForBluetooth = false

    func start() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            throw MicError.permissionDenied
        }
        sessionActive = true
        avoidBluetoothInput = true
        try startEngine()
    }

    /// Gives up on the substitute microphone and captures from the system
    /// default — the Bluetooth headset — for the rest of the session.
    ///
    /// Choosing the built-in mic over a Bluetooth headset keeps the headset out
    /// of its telephony profile, so playback stays full quality while
    /// recording. That is the right trade only while the built-in mic can
    /// actually hear the user. On 2026-08-03 it could not: the user was on
    /// AirPods at a desk, the Mac's own mic picked up nothing but room tone
    /// (−51.9 dBFS, 0.6% of frames above −40 dB), and their entire side of a
    /// six-minute meeting was lost — while the watchdog reported the mic
    /// healthy, because audio *was* arriving, just nobody's voice.
    ///
    /// Losing a speaker from the transcript is worse than losing playback
    /// fidelity: one is recoverable by taking the headphones off, the other is
    /// gone. So when the substitute is demonstrably deaf we hand the microphone
    /// back, which is no worse than never having substituted at all.
    func fallBackToDefaultInput() {
        guard sessionActive, substitutedForBluetooth else { return }
        avoidBluetoothInput = false
        log.notice("substitute mic heard nothing while the call was active; falling back to the default input")
        do {
            try startEngine()
            onNotice?("Switched to your headset's mic — the Mac's microphone wasn't picking you up.")
        } catch {
            onError?("The microphone stopped while switching devices: \(error.localizedDescription)")
        }
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

        // A Bluetooth default input drags the whole headset into the telephony
        // profile the moment capture starts: playback in the user's ears turns
        // low-fi and choppy for the entire recording (first report 2026-07-29 —
        // AirPods went unlistenable whenever record was on). Capture from a
        // wired mic instead; the headset keeps full-quality playback. The
        // route-change observer rebuilds the engine, so this re-evaluates
        // whenever devices come and go.
        substitutedForBluetooth = false
        if avoidBluetoothInput, let current = Self.defaultInputDevice(), Self.isBluetooth(current) {
            if let wired = Self.preferredWiredInput(), let unit = input.audioUnit {
                var device = wired.id
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                    0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status == noErr {
                    substitutedForBluetooth = true
                    log.notice("default input is Bluetooth; capturing from \(wired.name, privacy: .public) so the headset keeps full-quality playback")
                    onNotice?("Using \(wired.name) so your headphones keep full audio quality.")
                } else {
                    log.warning("couldn't switch capture to \(wired.name, privacy: .public) (err \(status)); staying on the Bluetooth mic")
                    onNotice?("Recording from your Bluetooth headset's mic — headphone audio may sound worse while recording.")
                }
            } else {
                // No wired mic on this Mac: the degradation is unavoidable,
                // but at least it isn't a mystery.
                onNotice?("Recording from your Bluetooth headset's mic — headphone audio may sound worse while recording.")
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

    // MARK: - Input-device choice (CoreAudio)

    /// The system's current default input device.
    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport = Self.transport(of: device)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The microphone to use when the default input is a Bluetooth headset:
    /// the built-in mic first — it exists on every portable and always works —
    /// then any wired external (USB / Thunderbolt / DisplayPort / PCI, e.g. a
    /// Studio Display). Virtual, aggregate, AirPlay, and continuity devices
    /// are never picked: capturing from those is a different feature.
    static func preferredWiredInput() -> (id: AudioDeviceID, name: String)? {
        let inputs = allDevices().filter { hasInputStreams($0) }
        let wiredTransports: [UInt32] = [
            kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeFireWire,
        ]
        let builtIn = inputs.first { transport(of: $0) == kAudioDeviceTransportTypeBuiltIn }
        let wired = inputs.first { wiredTransports.contains(transport(of: $0) ?? 0) }
        guard let chosen = builtIn ?? wired else { return nil }
        return (chosen, name(of: chosen) ?? "the Mac's microphone")
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func transport(of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? name as String? : nil
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
