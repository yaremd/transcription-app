import AVFoundation
import OSLog

/// Writes one capture stream's 16 kHz mono Float samples to an AAC (.m4a)
/// file as they arrive, so a finished meeting can later be re-transcribed
/// with the accurate model ("Improve transcript"). One instance per stream
/// per session. All disk I/O happens on a private serial queue so the audio
/// pipeline is never blocked; on any write error the recorder goes quiet
/// rather than disturbing the live session.
final class SessionAudioRecorder {
    private let queue = DispatchQueue(label: "com.yarem.LocalScribe.audiowriter", qos: .utility)
    private var file: AVAudioFile?
    private var reportedError = false
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private let log = Logger(subsystem: "com.yarem.LocalScribe", category: "AudioRecorder")

    init?(url: URL) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            try? FileManager.default.removeItem(at: url)
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            log.error("couldn't open \(url.lastPathComponent, privacy: .public) for writing: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let file = self.file else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format,
                                                frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            do {
                try file.write(from: buffer)
            } catch {
                if !self.reportedError {
                    self.reportedError = true
                    self.log.error("audio write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Flushes pending writes and finalizes the file (the header is written
    /// when the AVAudioFile is released).
    func finish() {
        queue.async { [weak self] in
            self?.file = nil
        }
    }
}
