import Foundation
import OSLog
import WhisperKit

/// Thin actor around WhisperKit. Loads a multilingual Whisper model on-device
/// and turns 16 kHz mono Float audio into text. Language can be forced (e.g.
/// "uk") or auto-detected within a set of plausible languages. The actor
/// serializes access so the mic and system-audio streams can share one model.
actor Transcriber {
    private var pipe: WhisperKit?
    private var language: String?          // ISO code like "uk"/"en"; nil = auto-detect
    private var allowedLanguages: [String] = []            // plausible codes in auto mode; empty = anything
    private(set) var loadedModel: String?
    private var vocabularyPrompt = ""      // custom terms joined into a Whisper prompt
    private var cachedVocabularyTokens: [Int]?
    private var detectedLanguage: [String: String] = [:]   // per source, in auto mode
    private var recentContext: [String: String] = [:]      // per source: tail of committed text
    private var filteredSegments = 0       // junk dropped this session, for tuning
    private let log = Logger(subsystem: "com.yarem.LocalScribe", category: "Transcriber")

    /// Sets the custom vocabulary that biases transcription toward the user's
    /// names/jargon. Tokenized lazily on the next transcribe (it needs the loaded
    /// model's tokenizer). A decoder prompt, so it works in any language.
    func setVocabulary(_ terms: [String]) {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        vocabularyPrompt = cleaned.joined(separator: ", ")
        cachedVocabularyTokens = nil
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

    /// Feeds a committed line back as context for the next passes on the same
    /// source: names keep their spelling, topic words are favored, sentences
    /// continue naturally. Only the tail is kept — Whisper's prompt window is
    /// small and recency is what matters.
    func noteCommitted(_ text: String, source: String) {
        let joined = ((recentContext[source].map { $0 + " " }) ?? "") + text
        recentContext[source] = String(joined.suffix(240))
    }

    /// Clears per-recording state; call when a new session starts.
    func beginSession() {
        detectedLanguage = [:]
        recentContext = [:]
        filteredSegments = 0
    }

    /// Unloads the current model so the next load() can pick a different one
    /// (used when the user flips the Fast/Accurate switch).
    func reset() {
        pipe = nil
        loadedModel = nil
        cachedVocabularyTokens = nil   // the tokenizer changes with the new model
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
    /// the preview keeps up; final passes spend more effort on accuracy — and
    /// may decode twice when the language is ambiguous.
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
        options.promptTokens = promptTokens(for: source, pipe: pipe)

        let candidates = await languageCandidates(samples: samples, source: source, mode: mode, pipe: pipe)
        var best: (text: String, score: Float, language: String?)?
        for candidate in candidates {
            options.language = candidate
            options.detectLanguage = (candidate == nil)
            guard let results = try? await pipe.transcribe(audioArray: samples, decodeOptions: options) else { continue }
            let kept = results.flatMap { $0.segments }.filter { trustworthy($0) }
            let text = Self.cleaned(kept.map { $0.text }.joined(separator: " "))
            let score = Self.decodeScore(kept, isEmpty: text.isEmpty)
            if best == nil || score > best!.score {
                best = (text, score, candidate ?? results.first?.language)
            }
        }
        guard let best else { return "" }
        if candidates.count > 1 {
            log.notice("bilingual arbitration on \(source, privacy: .public): picked \(best.language ?? "?", privacy: .public) (score \(best.score, format: .fixed(precision: 2)))")
        }

        // Remember what this source actually speaks. Final passes are informed
        // (arbitrated) choices; in unrestricted auto any detection is better
        // than none.
        if mode == .final || (language == nil && allowedLanguages.isEmpty),
           let lang = best.language, !lang.isEmpty,
           allowedLanguages.isEmpty || allowedLanguages.contains(lang) {
            detectedLanguage[source] = lang
        }
        return best.text
    }

    // MARK: - Language choice

    /// The language token(s) to decode with. One candidate = decode once.
    /// Two = the utterance is linguistically ambiguous: decode both and keep
    /// the better-scoring result. Bilingual speakers switch languages between
    /// utterances, detection alone mis-picks on short or accented audio, and a
    /// wrong pick makes Whisper transliterate ("Jak? V tebe sprawy?") or
    /// outright translate — a second decode is cheaper than a ruined line.
    private func languageCandidates(samples: [Float], source: String, mode: TranscribeMode, pipe: WhisperKit) async -> [String?] {
        if let language { return [language] }
        let cached = detectedLanguage[source]
        if allowedLanguages.isEmpty { return [cached] }        // unrestricted auto
        guard mode == .final else { return [cached ?? allowedLanguages.first] }
        guard allowedLanguages.count > 1 else { return [allowedLanguages.first] }

        if let detection = try? await pipe.detectLangauge(audioArray: samples) {
            let ranked = allowedLanguages
                .map { (code: $0, prob: detection.langProbs[$0] ?? 0) }
                .sorted { $0.prob > $1.prob }
            let top = ranked[0], next = ranked[1]
            if top.prob >= 0.75 || next.prob == 0 || top.prob >= 4 * next.prob {
                detectedLanguage[source] = top.code
                return [top.code]
            }
            return [top.code, next.code]
        }
        // Detection unavailable — try both plausible languages.
        return [allowedLanguages[0], allowedLanguages[1]]
    }

    /// Mean decoder confidence of the kept segments; empty output ranks last.
    private static func decodeScore(_ segments: [TranscriptionSegment], isEmpty: Bool) -> Float {
        guard !isEmpty, !segments.isEmpty else { return -10 }
        let total = segments.reduce(Float(0)) { $0 + $1.avgLogprob }
        return total / Float(segments.count)
    }

    // MARK: - Decoder prompt

    /// Custom vocabulary + this source's recent transcript, as prompt tokens.
    /// Vocabulary first, context last — recency weighs most with the decoder.
    /// Capped well under Whisper's 224-token prompt budget so the audio keeps
    /// most of the context window.
    private func promptTokens(for source: String, pipe: WhisperKit) -> [Int]? {
        guard let tokenizer = pipe.tokenizer else { return nil }
        var tokens: [Int] = []
        if !vocabularyPrompt.isEmpty {
            if cachedVocabularyTokens == nil {
                cachedVocabularyTokens = Array(
                    tokenizer.encode(text: " " + vocabularyPrompt)
                        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                        .prefix(80))
            }
            tokens += cachedVocabularyTokens ?? []
        }
        if let context = recentContext[source], !context.isEmpty {
            tokens += tokenizer.encode(text: " " + context)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                .suffix(120)
        }
        return tokens.isEmpty ? nil : tokens
    }

    // MARK: - Output quality filters

    /// Drops segments the decoder itself marked as dubious: probable silence,
    /// degenerate repetition loops, and low-confidence 1–2 word fragments (the
    /// "you" / "Thank you." Whisper invents from near-silence). Reasons are
    /// logged as metrics only — never transcript text — so tuning stays
    /// data-driven without spoken content leaving the app.
    private func trustworthy(_ segment: TranscriptionSegment) -> Bool {
        let words = segment.text.split(whereSeparator: { $0.isWhitespace }).count
        let reason: String?
        if segment.noSpeechProb > 0.8 && segment.avgLogprob < -0.7 {
            reason = "probable-silence"
        } else if segment.noSpeechProb > 0.6 && segment.avgLogprob < -1.0 {
            reason = "weak-silence"
        } else if segment.compressionRatio > 2.6 {
            reason = "repetition-loop"
        } else if words > 0 && words <= 2 && segment.avgLogprob < -1.0 {
            reason = "short-junk"
        } else {
            reason = nil
        }
        guard let reason else { return true }
        filteredSegments += 1
        log.notice("filtered segment #\(self.filteredSegments) (\(reason, privacy: .public)): words=\(words) noSpeech=\(segment.noSpeechProb, format: .fixed(precision: 2)) logprob=\(segment.avgLogprob, format: .fixed(precision: 2))")
        return false
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
