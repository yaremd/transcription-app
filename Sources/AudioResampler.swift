import AVFoundation

/// Converts arbitrary PCM buffers to 16 kHz mono Float32 (Whisper's input
/// format), handling sample-rate conversion and stereo->mono downmix. One
/// instance per capture source (input format is stable for a session).
final class AudioResampler {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?

    func resample(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard input.frameLength > 0 else { return nil }
        if converter == nil {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
