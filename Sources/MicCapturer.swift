import AVFoundation

/// Captures the local microphone with AVAudioEngine, resamples to 16 kHz mono
/// Float, and streams the samples out. Triggers the macOS microphone prompt.
final class MicCapturer {
    var onSamples: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let resampler = AudioResampler()

    func start() throws {
        let input = engine.inputNode
        // Voice processing = Apple's echo cancellation + noise suppression.
        // Without it, call audio played through speakers bleeds into the mic
        // and every phrase lands twice: once as "You", once as "Others".
        // Ducking is disabled so the call we're also capturing isn't quieted.
        // If enabling fails (exotic audio devices), fall back to the raw mic.
        if !input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {}
        }
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let samples = self.resampler.resample(buffer) else { return }
            self.onSamples?(samples)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}
