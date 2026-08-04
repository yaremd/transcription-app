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
    /// The system default input at the moment this engine was built.
    ///
    /// The configuration-change observer fires for *any* change to the engine,
    /// including the one our own Bluetooth substitution provokes: setting
    /// `kAudioOutputUnitProperty_CurrentDevice` is itself a configuration
    /// change, so rebuilding in response set the device again, which posted
    /// again. On 2026-08-04 that loop rebuilt the engine 15 times in the first
    /// 2.85 seconds of a session and cost the opening 2.4 seconds of audio —
    /// the meeting's first words, every time.
    ///
    /// What the observer exists for is the device *the system* hands us
    /// changing (AirPods connect, an interface unplugs). That is what this
    /// records, and only a change to it warrants a rebuild.
    private var defaultInputAtStart: AudioDeviceID?
    /// Engines built this session — an invariant the smoke test can hold onto.
    private(set) var engineStarts = 0
    private let log = Logger(subsystem: "com.yarem.Seal", category: "Mic")
    private var sessionActive = false

    // Written from the audio thread, read by the watchdog on the main thread.
    private let meterLock = NSLock()
    private var tapPeak: Float = 0          // loudest sample the tap saw
    private var samplesDelivered = false    // resampled audio actually left the tap
    private var lastBufferAt = Date()       // when the tap last handed us anything

    private var watchdog: Timer?
    private var watchdogStart = Date()

    /// Whether the mic is still being supervised. It must stay true for the
    /// whole of a live session — see `MicWatchdogSmokeTests`.
    var isWatching: Bool { watchdog != nil }

    /// A live mic always has at least this much noise floor; below it for the
    /// whole window means the device is delivering nothing.
    private let deadPeak: Float = 1e-4
    private let judgeSeconds = 3.5

    /// Whether the opening verdict has been reached. After it, the watchdog
    /// stops asking "did this device ever work" and starts asking "is it still
    /// working" — the question that used to go unasked for the rest of the
    /// session.
    private var startupJudged = false
    /// No buffers for this long means the device stopped. A live microphone
    /// never falls silent — it delivers its own noise floor continuously — so
    /// this is a dropout, not a quiet room. Generous, because the tap hands us
    /// roughly twelve buffers a second and a brief hiccup is not a failure.
    private let stallSeconds: TimeInterval = 8
    /// Engine rebuilds spent on a stalled mic this session, and whether the
    /// user has been told we ran out of them.
    private var stallRecoveries = 0
    private let maxStallRecoveries = 3
    private var reportedStall = false

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
        stallRecoveries = 0
        reportedStall = false
        engineStarts = 0
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
        engineStarts += 1
        // Read before the substitution below, which changes the engine's device
        // but never the system's.
        defaultInputAtStart = Self.defaultInputDevice()
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

        startupJudged = false
        meterLock.lock()
        tapPeak = 0
        samplesDelivered = false
        lastBufferAt = Date()
        meterLock.unlock()

        // The tap captures this resampler instance directly so a restart can
        // swap in a fresh one without racing the audio thread.
        let resampler = AudioResampler()
        self.resampler = resampler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.notePeak(of: buffer)
            self.meterLock.lock()
            self.lastBufferAt = Date()      // the heartbeat the stall check reads
            self.meterLock.unlock()
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
            self?.handleConfigurationChange()
        }

        armWatchdog()
    }

    /// The engine's configuration changed. Rebuild only if the device the
    /// *system* gives us is no longer the one this engine was built on.
    ///
    /// Internal rather than inline in the observer so the smoke test can drive
    /// it without unplugging anything.
    func handleConfigurationChange() {
        guard sessionActive else { return }
        guard Self.defaultInputDevice() != defaultInputAtStart else {
            // Same device we started on, so this is our own substitution
            // talking (or a rate change on the one device). Rebuilding here is
            // precisely what caused the startup loop. If the engine genuinely
            // did stop delivering, the stall check picks it up within
            // `stallSeconds` — that backstop is why ignoring this is safe.
            log.debug("engine configuration changed on the same input device; not rebuilding")
            return
        }
        log.notice("audio route changed; restarting capture")
        do { try startEngine() } catch {
            onError?("The microphone stopped after an audio device change: \(error.localizedDescription)")
        }
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
        let silentFor = Date().timeIntervalSince(lastBufferAt)
        meterLock.unlock()

        // Past the opening verdict the question changes. A device that starts
        // fine and stops later used to be invisible: this check disarmed itself
        // the moment it saw audio, so on 2026-08-03 a Studio Display mic that
        // delivered 1.6 seconds and quit went unnoticed for the remaining 46
        // minutes of a meeting, and the user's whole side of it was lost.
        if startupJudged {
            guard silentFor >= stallSeconds else { return }
            recoverFromStall(silentFor: silentFor)
            return
        }

        if delivered && peak >= deadPeak {
            startupJudged = true       // healthy start — keep watching for a stall
            // This engine works, so the restart budget is about *consecutive*
            // failures: a long meeting with the odd device hiccup should not
            // run out of retries because of stalls it already recovered from.
            stallRecoveries = 0
            return
        }
        guard Date().timeIntervalSince(watchdogStart) >= judgeSeconds else { return }

        startupJudged = true           // reported once; the timer stays on stall duty
        // A rebuilt engine that comes up silent is the stall path's business,
        // and it has its own message. Reporting here too would stack a second
        // error on the user for one fault — `appendError` concatenates.
        guard stallRecoveries == 0 else { return }
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

    /// The tap has gone quiet mid-session. Rebuild the engine on whatever the
    /// current default input is — a device that dropped out often comes back,
    /// and the rebuild is the same move the route-change observer already makes
    /// — then give up loudly rather than keep recording silence.
    ///
    /// Restarting costs a fraction of a second of audio. Not restarting costs
    /// the rest of the meeting, which is what it cost on 2026-08-03.
    private func recoverFromStall(silentFor: TimeInterval) {
        guard stallRecoveries < maxStallRecoveries else {
            guard !reportedStall else { return }
            reportedStall = true
            watchdog?.invalidate()
            watchdog = nil
            log.error("microphone stayed dead through \(self.maxStallRecoveries) restarts; giving up for this session")
            onError?("The microphone stopped sending audio and restarting it didn't help. Check System Settings → Sound → Input, then Stop and Start the recording.")
            return
        }
        stallRecoveries += 1
        log.error("microphone delivered nothing for \(silentFor, format: .fixed(precision: 1))s; rebuilding the engine (attempt \(self.stallRecoveries) of \(self.maxStallRecoveries))")
        do {
            // Rebuilds the tap, resets the heartbeat, and re-arms this watchdog
            // for a fresh opening verdict on the new engine.
            try startEngine()
            onNotice?("The microphone stopped responding — restarting it.")
        } catch {
            onError?("The microphone stopped and couldn't be restarted: \(error.localizedDescription)")
        }
    }
}
