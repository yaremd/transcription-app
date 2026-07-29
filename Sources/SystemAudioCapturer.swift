import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import AVFoundation
import OSLog

/// Captures system-wide output audio (the *other* participants in a call, or
/// anything playing through your Mac), resamples it to 16 kHz mono Float, and
/// streams the samples out.
///
/// Two engines, chosen by OS:
///
/// - macOS 14.2+ — a **Core Audio process tap**: coreaudiod hands us the mixed
///   output directly, with no capture engine attached to the display path.
///   ScreenCaptureKit's audio capture disturbed the *output* device — with
///   Bluetooth headphones, starting a recording made playback lag and drop to
///   silence until the headset disconnected (2026-07-29 field report, still
///   present after the mic had already moved off the headset). The tap also
///   needs only the "System Audio Recording" permission, not Screen Recording.
/// - Older systems — the original ScreenCaptureKit path.
final class SystemAudioCapturer: NSObject, SCStreamOutput {
    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.yarem.Seal.systemaudio")
    private let resampler = AudioResampler()
    private let log = Logger(subsystem: "com.yarem.Seal", category: "SystemAudio")

    // Process-tap state (macOS 14.2+).
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapAVFormat: AVAudioFormat?

    // ScreenCaptureKit state (fallback for macOS < 14.2).
    private var stream: SCStream?

    func start() {
        if #available(macOS 14.2, *) {
            do {
                try startProcessTap()
                log.info("system audio capture started (process tap)")
            } catch {
                log.error("process tap failed: \(error.localizedDescription, privacy: .public); falling back to ScreenCaptureKit")
                startScreenCaptureKit()
            }
        } else {
            startScreenCaptureKit()
        }
    }

    func stop() {
        stopProcessTap()
        stream?.stopCapture { _ in }
        stream = nil
    }

    // MARK: - Core Audio process tap (macOS 14.2+)

    private struct TapError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @available(macOS 14.2, *)
    private func startProcessTap() throws {
        guard tapID == kAudioObjectUnknown else { return }

        // Tap everything except our own audio — same semantics as
        // SCStreamConfiguration.excludesCurrentProcessAudio.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError(message: "couldn't create the system audio tap (err \(status)) — check System Settings → Privacy & Security → Screen & System Audio Recording")
        }
        tapID = newTapID

        // The tap's stream format (typically Float32 stereo at the output rate).
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stopProcessTap()
            throw TapError(message: "couldn't read the tap's audio format (err \(status))")
        }
        tapAVFormat = format

        // A private aggregate device hosting just the tap; auto-starts with us.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Seal System Audio",
            kAudioAggregateDeviceUIDKey as String: "com.yarem.Seal.systemtap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            stopProcessTap()
            throw TapError(message: "couldn't create the capture device for the tap (err \(status))")
        }
        aggregateID = newAggregateID

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, sampleQueue) { [weak self] _, inputData, _, _, _ in
            self?.handleTapBuffers(inputData)
        }
        guard status == noErr, let procID else {
            stopProcessTap()
            throw TapError(message: "couldn't attach to the capture device (err \(status))")
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stopProcessTap()
            throw TapError(message: "couldn't start system audio capture (err \(status))")
        }
    }

    private func stopProcessTap() {
        guard #available(macOS 14.2, *) else { return }
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        tapAVFormat = nil
    }

    /// IO callback: wrap the tap's buffers in a PCM buffer and resample. Runs
    /// on `sampleQueue`, same as the ScreenCaptureKit path did.
    private func handleTapBuffers(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = tapAVFormat else { return }
        let byteCount = inputData.pointee.mBuffers.mDataByteSize
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let frames = AVAudioFrameCount(byteCount / bytesPerFrame)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
                ?? Self.copiedBuffer(from: inputData, format: format, frames: frames) else { return }
        if pcm.frameLength == 0 { pcm.frameLength = frames }
        guard let samples = resampler.resample(pcm), !samples.isEmpty else { return }
        onSamples?(samples)
    }

    /// Fallback wrap when the no-copy path declines the buffer list.
    private static func copiedBuffer(from list: UnsafePointer<AudioBufferList>,
                                     format: AVAudioFormat,
                                     frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for (index, buffer) in source.enumerated() where index < destination.count {
            guard let from = buffer.mData, let to = destination[index].mData else { continue }
            let bytes = min(buffer.mDataByteSize, destination[index].mDataByteSize)
            memcpy(to, from, Int(bytes))
        }
        return pcm
    }

    /// Our own process, as Core Audio objects — excluded from the tap so any
    /// sound the app itself makes never loops into the transcript.
    @available(macOS 14.2, *)
    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeBytes(of: &pid) { pidBytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(pidBytes.count), pidBytes.baseAddress, &size, &object)
        }
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    // MARK: - ScreenCaptureKit (macOS < 14.2)

    private func startScreenCaptureKit() {
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
                log.info("system audio capture started (ScreenCaptureKit)")
            } catch {
                log.error("system audio start failed: \(error.localizedDescription, privacy: .public)")
                onError?("System audio: \(error.localizedDescription)")
            }
        }
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
