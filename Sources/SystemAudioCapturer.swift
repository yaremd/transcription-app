import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFoundation
import OSLog

/// Captures system-wide output audio (the *other* participants in a call, or
/// anything playing through your Mac) with ScreenCaptureKit, resamples it to
/// 16 kHz mono Float, and streams the samples out. Triggers the macOS Screen &
/// System Audio Recording permission on first run.
///
/// NOTE: ScreenCaptureKit is the reliable path. Once proven, this single file
/// can be swapped for a Core Audio process tap to avoid the screen-recording
/// permission — nothing else in the app changes.
final class SystemAudioCapturer: NSObject, SCStreamOutput {
    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.yarem.Seal.systemaudio")
    private let resampler = AudioResampler()
    private let log = Logger(subsystem: "com.yarem.Seal", category: "SystemAudio")

    func start() {
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else {
                    onError?("No display available to attach audio capture to.")
                    return
                }

                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                self.stream = stream
                log.info("system audio capture started")
            } catch {
                log.error("system audio start failed: \(error.localizedDescription, privacy: .public)")
                onError?("System audio: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              var asbd = formatDesc.audioStreamBasicDescription,
              let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr, let samples = resampler.resample(pcm) else { return }
        onSamples?(samples)
    }
}
