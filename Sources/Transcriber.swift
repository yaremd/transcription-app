import Foundation
import WhisperKit

/// Thin actor around WhisperKit. Loads a multilingual Whisper model on-device
/// and turns 16 kHz mono Float audio into text. Language can be forced (e.g.
/// "uk") or left to auto-detect. The actor serializes access so the mic and
/// system-audio streams can share one model.
actor Transcriber {
    private var pipe: WhisperKit?
    private var language: String?          // ISO code like "uk"/"en"; nil = auto-detect
    private var allowedLanguages: [String] = []            // plausible codes in auto mode; empty = anything
    private(set) var loadedModel: String?
    private var vocabularyPrompt = ""      // custom terms joined into a Whisper prompt
    private var cachedPromptTokens: [Int]?
    private var detectedLanguage: [String: String] = [:]   // per source, in auto mode

    /// Sets the custom vocabulary that biases transcription toward the user's
    /// names/jargon. Tokenized lazily on the next transcribe (it needs the loaded
    /// model's tokenizer). A decoder prompt, so it works in any language.
    func setVocabulary(_ terms: [String]) {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        vocabularyPrompt = cleaned.joined(separator: ", ")
        cachedPromptTokens = nil
    }

    var isLoaded: Bool { pipe != nil }

    /// `forced` pins every pass to one language. When nil, detection runs but
    /// is constrained to `allowed`: Whisper free-detects across 99 languages
    /// and, on short or accented audio, happily picks Malay or Korean — and
    /// then *translates* the speech into it. Restricting to the languages the
    /// user actually speaks eliminates that entire failure mode.
    func setLanguagePolicy(forced: String?, allowed: [String]) {
        language = forced
        allowedLanguages = allowed
    }

    /// Clears per-recording state; call when a new session starts.
    func beginSession() {
        detectedLanguage = [:]
    }

    /// Unloads the current model so the next load() can pick a different one
    /// (used when the user flips the Fast/Accurate switch).
    func reset() {
        pipe = nil
        loadedModel = nil
        cachedPromptTokens = nil   // the tokenizer changes with the new model
    }

    func load(candidates: [String]) async throws {
        guard pipe == nil else { return }
        var lastError: Error?
        for name in candidates {
            do {
                pipe = try await WhisperKit(WhisperKitConfig(model: name, prewarm: true))
                loadedModel = name
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "Transcriber", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "No transcription model could be loaded."])
    }

    /// `source` keys the auto-detected language ("You" may speak a different
    /// language than the call audio). Live passes skip everything optional so
    /// the preview keeps up; final passes spend more effort on accuracy.
    func transcribe(_ samples: [Float], source: String, mode: TranscribeMode) async -> String {
        guard let pipe, samples.count >= 1600 else { return "" }   // need ≥ 0.1s of audio

        var options = DecodingOptions()
        options.task = .transcribe
        options.skipSpecialTokens = true
        options.withoutTimestamps = true   // timestamps are unused; decoding is faster without them
        options.suppressBlank = true
        switch mode {
        case .live:
            options.temperatureFallbackCount = 0   // no retry ladder: the preview must keep up
        case .final:
            options.temperatureFallbackCount = 2
        }
        options.language = await resolveLanguage(samples: samples, source: source, mode: mode, pipe: pipe)
        options.detectLanguage = (options.language == nil)
        if !vocabularyPrompt.isEmpty {
            if cachedPromptTokens == nil, let tok = pipe.tokenizer {
                cachedPromptTokens = tok.encode(text: " " + vocabularyPrompt)
                    .filter { $0 < tok.specialTokens.specialTokenBegin }
            }
            options.promptTokens = cachedPromptTokens
        }

        do {
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            // Unrestricted auto mode only: remember whatever Whisper detected.
            if language == nil, allowedLanguages.isEmpty,
               let detected = results.first?.language, !detected.isEmpty {
                detectedLanguage[source] = detected
            }
            let text = results
                .flatMap { $0.segments }
                .filter { Self.isTrustworthy($0) }
                .map { $0.text }
                .joined(separator: " ")
            return Self.cleaned(text)
        } catch {
            return ""
        }
    }

    /// Picks the language token for a pass. Forced language wins. Otherwise:
    /// live passes and short utterances reuse what this source spoke before
    /// (detection on a second of audio is a coin flip); final passes on enough
    /// audio re-detect — but an implausible result (not in `allowedLanguages`)
    /// is discarded in favor of the cached language, because acting on it makes
    /// Whisper *translate* the speech into the mis-detected language.
    private func resolveLanguage(samples: [Float], source: String, mode: TranscribeMode, pipe: WhisperKit) async -> String? {
        if let language { return language }
        let cached = detectedLanguage[source]
        let fallback = cached ?? allowedLanguages.first    // nil only in unrestricted auto
        guard mode == .final else { return fallback }
        guard Double(samples.count) / 16_000 >= 1.2 else { return fallback }
        guard let detected = try? await pipe.detectLangauge(audioArray: samples).language else {
            return fallback
        }
        if allowedLanguages.isEmpty || allowedLanguages.contains(detected) {
            detectedLanguage[source] = detected
            return detected
        }
        return fallback
    }

    // MARK: - Output quality filters

    /// Drops segments the decoder itself marked as dubious: probable silence
    /// (high no-speech probability with weak confidence) and degenerate
    /// repetition loops (high compression ratio).
    private static func isTrustworthy(_ segment: TranscriptionSegment) -> Bool {
        if segment.noSpeechProb > 0.8 && segment.avgLogprob < -0.7 { return false }
        if segment.compressionRatio > 2.6 { return false }
        return true
    }

    /// Stock phrases Whisper invents on near-silence (learned from YouTube
    /// outros). Compared against the *whole* normalized output, so a real
    /// "thank you" inside a sentence is never touched.
    private static let hallucinationPhrases: Set<String> = [
        "thank you for watching", "thanks for watching", "subscribe to the channel",
        "please subscribe", "see you in the next video",
        "дякую за перегляд", "підписуйтесь на канал", "до зустрічі в наступному відео",
        "субтитри створені спільнотою amara org", "субтитри створював dimatorzok",
        "спасибо за просмотр", "продолжение следует", "субтитры сделал dimatorzok",
    ]

    private static func cleaned(_ raw: String) -> String {
        // Whisper wraps non-speech events in brackets: [музика], [applause], …
        var text = raw.replacingOccurrences(of: #"\[[^\]\n]{1,40}\]"#,
                                            with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if normalized.isEmpty || hallucinationPhrases.contains(normalized) { return "" }
        return text
    }
}
