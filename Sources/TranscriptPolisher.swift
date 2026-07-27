import AVFoundation
import Foundation
import WhisperKit

/// Re-transcribes a finished meeting from its saved audio with the accurate
/// model, replacing the rough live lines with a clean, full-context pass —
/// the live view optimizes for speed, this pass optimizes for the record.
/// Loads its own WhisperKit instance so the live transcriber is untouched,
/// and releases it when the pass ends.
actor TranscriptPolisher {
    struct PolishError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Accuracy first — full large-v3 before the faster distillations.
    private static let modelCandidates = ["large-v3", "large-v3_turbo", "large-v3-v20240930_turbo", "small"]

    /// Whisper's stock inventions on near-silence; a whole line matching one
    /// of these is dropped (same list the live path uses).
    private static let hallucinationPhrases: Set<String> = [
        "thank you for watching", "thanks for watching", "subscribe to the channel",
        "please subscribe", "see you in the next video",
        "дякую за перегляд", "підписуйтесь на канал", "до зустрічі в наступному відео",
        "субтитри створені спільнотою amara org", "субтитри створював dimatorzok",
        "спасибо за просмотр", "продолжение следует", "субтитры сделал dimatorzok",
    ]

    /// Transcribes both saved streams and interleaves them chronologically.
    /// `meeting.date` anchors segment times to wall-clock so note links keep
    /// working after the replacement.
    func polish(meeting: Meeting, micURL: URL?, systemURL: URL?, vocabulary: [String]) async throws -> [StoredLine] {
        var pipe: WhisperKit?
        var lastError: Error?
        for name in Self.modelCandidates {
            do {
                pipe = try await WhisperKit(WhisperKitConfig(model: name, prewarm: true))
                break
            } catch {
                lastError = error
            }
        }
        guard let pipe else {
            throw PolishError(message: "Couldn't load the accurate model. \(lastError?.localizedDescription ?? "")")
        }

        var options = DecodingOptions()
        options.task = .transcribe
        options.skipSpecialTokens = true
        options.suppressBlank = true
        options.temperatureFallbackCount = 2
        options.withoutTimestamps = false   // times are what let the two sides interleave
        if let code = TranscriptLanguage(rawValue: meeting.language)?.code {
            options.language = code
            options.detectLanguage = false
        }
        // In auto mode the language is chosen per stream below — but always
        // from the languages the user actually speaks, never free detection
        // across Whisper's 99 (which loves calling Ukrainian "Russian").
        let allowed = TranscriptLanguage(rawValue: meeting.language)?.allowedCodes ?? ["uk", "en"]
        if !vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            options.promptTokens = Array(
                tokenizer.encode(text: " " + vocabulary.joined(separator: ", "))
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                    .prefix(120))
        }
        let ruSuppress = Self.russianMarkerTokens(pipe: pipe)

        var utterances: [(speaker: String, start: Double, text: String)] = []
        if let micURL, let audio = Self.loadAudio(micURL) {
            utterances += try await transcribeStream(pipe: pipe, audio: audio, speaker: "You",
                                                     options: options, allowed: allowed, ruSuppress: ruSuppress)
        }
        if let systemURL, let audio = Self.loadAudio(systemURL) {
            utterances += try await transcribeStream(pipe: pipe, audio: audio, speaker: "Others",
                                                     options: options, allowed: allowed, ruSuppress: ruSuppress)
        }
        guard !utterances.isEmpty else {
            throw PolishError(message: "The saved audio contained nothing transcribable.")
        }
        utterances.sort { $0.start < $1.start }

        // Interleave and drop echo ghosts: a "You" line that duplicates an
        // "Others" phrase spoken within the same ~12 s came from the speakers,
        // not the user.
        var lines: [StoredLine] = []
        for utterance in utterances {
            if utterance.speaker == "You" {
                let normalized = AudioMonitor.normalizedForEcho(utterance.text)
                let isGhost = utterances.contains {
                    $0.speaker == "Others"
                        && abs($0.start - utterance.start) < 12
                        && AudioMonitor.isEchoPair(normalized, AudioMonitor.normalizedForEcho($0.text))
                }
                if isGhost { continue }
            }
            lines.append(StoredLine(speaker: utterance.speaker,
                                    text: utterance.text,
                                    at: meeting.date.addingTimeInterval(utterance.start)))
        }
        return lines
    }

    /// One stream, full length. Whisper's sentence-ish segments are merged
    /// into utterances wherever the gap between them stays under ~1.2 s.
    /// In auto mode the stream's language is decided here — detected once on
    /// the stream's opening, clamped to the allowed set — so the two sides of
    /// a call can be different languages, but neither can drift off into one
    /// nobody was speaking.
    private func transcribeStream(pipe: WhisperKit, audio: [Float], speaker: String,
                                  options: DecodingOptions, allowed: [String],
                                  ruSuppress: [Int]) async throws -> [(String, Double, String)] {
        guard audio.count >= 1600 else { return [] }
        var options = options
        if options.language == nil {
            if allowed.count == 1 {
                options.language = allowed.first
            } else if let detection = try? await pipe.detectLangauge(audioArray: Array(audio.prefix(30 * 16_000))) {
                options.language = allowed.max {
                    (detection.langProbs[$0] ?? 0) < (detection.langProbs[$1] ?? 0)
                }
            } else {
                options.language = allowed.first
            }
            options.detectLanguage = false
        }
        if options.language == "uk" {
            options.supressTokens = ruSuppress
        }
        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options)

        var merged: [(String, Double, String)] = []
        var text = ""
        var start = 0.0
        var lastEnd = -10.0
        for segment in results.flatMap({ $0.segments }) {
            guard Self.trustworthy(segment) else { continue }
            let piece = Self.cleaned(segment.text)
            guard !piece.isEmpty else { continue }
            if Double(segment.start) - lastEnd > 1.2, !text.isEmpty {
                merged.append((speaker, start, text))
                text = ""
            }
            if text.isEmpty { start = Double(segment.start) }
            text += (text.isEmpty ? "" : " ") + piece
            lastEnd = Double(segment.end)
        }
        if !text.isEmpty { merged.append((speaker, start, text)) }
        return merged.filter { !Self.hallucinationPhrases.contains(AudioMonitor.normalizedForEcho($0.2)) }
    }

    /// Token ids containing letters Ukrainian never uses (ы э ъ ё) —
    /// suppressed while decoding as Ukrainian so Russian output is impossible.
    private static func russianMarkerTokens(pipe: WhisperKit) -> [Int] {
        guard let tokenizer = pipe.tokenizer else { return [] }
        let markers = CharacterSet(charactersIn: "ыЫэЭъЪёЁ")
        var found: [Int] = []
        for id in 0..<tokenizer.specialTokens.specialTokenBegin
        where tokenizer.decode(tokens: [id]).rangeOfCharacter(from: markers) != nil {
            found.append(id)
        }
        return found
    }

    private static func trustworthy(_ segment: TranscriptionSegment) -> Bool {
        if segment.noSpeechProb > 0.8 && segment.avgLogprob < -0.7 { return false }
        if segment.noSpeechProb > 0.6 && segment.avgLogprob < -1.0 { return false }
        if segment.compressionRatio > 2.6 { return false }
        // Short fragments born of silence — the "Дякую"/"you" Whisper invents
        // between utterances. A real one/two-word answer carries genuine speech,
        // so its no-speech probability stays low and it still passes.
        let words = segment.text.split(whereSeparator: { $0.isWhitespace }).count
        if words > 0 && words <= 2 && (segment.avgLogprob < -1.0 || segment.noSpeechProb > 0.6) { return false }
        return true
    }

    private static func cleaned(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\[[^\]\n]{1,40}\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a saved stream back as 16 kHz mono Float (the recorder wrote it
    /// in that shape; resample defensively if a file ever differs).
    private static func loadAudio(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        if format.sampleRate == 16_000, format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return AudioResampler().resample(buffer)
    }
}
