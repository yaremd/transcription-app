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
    /// Per source: how many final lines each language has produced this
    /// session. The leader is the source's "dominant" language — the momentum
    /// that keeps one noisy detection from flipping a Ukrainian meeting into
    /// English (which Whisper then *translates* into) or Russian.
    private var languageTally: [String: [String: Int]] = [:]
    /// Token ids containing letters Ukrainian never uses (ы э ъ ё) — cached
    /// per loaded model; suppressed whenever decoding as Ukrainian.
    private var cachedRussianMarkerTokens: [Int]?
    private var filteredSegments = 0       // junk dropped this session, for tuning
    /// Memory coordination (tight-RAM Macs): whether a recording is currently
    /// using the speech model, and when it last ran — so the model is released
    /// for the notes model only when it's genuinely idle. See `releaseIfIdle`.
    private var recordingActive = false
    private var lastTranscribeAt = Date.distantPast
    private let log = Logger(subsystem: "com.yarem.Seal", category: "Transcriber")

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
        languageTally = [:]
        filteredSegments = 0
        recordingActive = true
    }

    /// Marks the recording finished — the speech model may now be released for
    /// the notes model once it goes idle (see `releaseIfIdle`).
    func endSession() { recordingActive = false }

    /// Releases the speech model to free RAM for the notes model, but only when
    /// it's safe: no recording is using it, and it hasn't transcribed in the
    /// last `minIdle` seconds (so a just-ended recording's final commits have
    /// settled). The next recording reloads it; a no-op otherwise. For
    /// post-meeting memory coordination on memory-tight Macs.
    func releaseIfIdle(minIdle: TimeInterval) {
        guard pipe != nil, !recordingActive,
              Date().timeIntervalSince(lastTranscribeAt) >= minIdle else { return }
        reset()
        log.notice("released the speech model to free memory for notes")
    }

    /// Unloads the current model so the next load() can pick a different one
    /// (used when the user flips the Fast/Accurate switch).
    func reset() {
        pipe = nil
        loadedModel = nil
        cachedVocabularyTokens = nil   // the tokenizer changes with the new model
        cachedRussianMarkerTokens = nil
    }

    func load(candidates: [String]) async throws {
        guard pipe == nil else { return }
        var lastError: Error?
        for name in candidates {
            do {
                let loaded = try await WhisperKit(Self.config(for: name))
                pipe = loaded
                loadedModel = name
                // Warm the Russian-marker suppress list while we're already in
                // "loading" — scanning the vocabulary once beats stalling the
                // first Ukrainian utterance.
                _ = russianMarkerTokens(pipe: loaded)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "Transcriber", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "No transcription model could be loaded."])
    }

    /// Local-first: when the variant is already downloaded we hand WhisperKit
    /// the folder, which sends `setupModels` down its local branch and skips the
    /// Hub API entirely — the difference between transcribing on a plane and
    /// failing to start (YAR-70). Otherwise we fall through to a download, but
    /// always into our own cache root rather than the user's Documents folder
    /// (YAR-71). `downloadBase` also seeds `tokenizerFolder`, so the tokenizer
    /// resolves from the same place instead of reaching for the network.
    static func config(for variant: String) -> WhisperKitConfig {
        let base = ModelStore.hubBase
        if let cached = ModelStore.cachedWhisperFolder(variant: variant) {
            return WhisperKitConfig(model: variant,
                                    downloadBase: base,
                                    modelFolder: cached.path,
                                    prewarm: true,
                                    download: false)
        }
        return WhisperKitConfig(model: variant, downloadBase: base, prewarm: true)
    }

    /// `source` keys the auto-detected language ("You" may speak a different
    /// language than the call audio). Live passes skip everything optional so
    /// the preview keeps up; final passes spend more effort on accuracy — and
    /// may decode twice when the language is ambiguous.
    func transcribe(_ samples: [Float], source: String, mode: TranscribeMode) async -> String {
        guard let pipe, samples.count >= 1600 else { return "" }   // need ≥ 0.1s of audio
        lastTranscribeAt = Date()

        let candidates = await languageCandidates(samples: samples, source: source, mode: mode, pipe: pipe)
        let dominant = dominantLanguage(for: source)
        // The language arbitration gives a head start to the one it shouldn't
        // lightly abandon: the established dominant once momentum exists, or —
        // while still bootstrapping — the acoustic detection's pick, which
        // `languageCandidates` offers first. Without this, a short meeting has
        // no momentum yet and Whisper's fluent English translations of
        // Ukrainian would win on raw confidence alone.
        let protected = dominant ?? (candidates.count > 1 ? (candidates.first ?? nil) : nil)
        var best: (text: String, score: Float, confidence: Float, language: String?)?
        /// Whether the language this source has been speaking all session heard
        /// nothing in this audio — see the silence check below.
        var dominantHeardNothing = false
        for candidate in candidates {
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
            options.language = candidate
            options.detectLanguage = (candidate == nil)
            // Context is offered per candidate: a prompt in the wrong script
            // would drag the decoder toward that language (one mis-detected
            // line then poisons every one after it).
            options.promptTokens = promptTokens(for: source, pipe: pipe, decodingAs: candidate)
            // Decoding as Ukrainian: ban every token containing a letter
            // Ukrainian never uses (ы э ъ ё) — Russian output becomes
            // impossible without touching legitimate Ukrainian text.
            if (candidate ?? language) == "uk" {
                options.supressTokens = russianMarkerTokens(pipe: pipe)
            }
            guard let results = try? await pipe.transcribe(audioArray: samples, decodeOptions: options) else { continue }
            let kept = results.flatMap { $0.segments }.filter { trustworthy($0) }
            let text = Self.cleaned(kept.map { $0.text }.joined(separator: " "))
            let confidence = Self.decodeScore(kept, isEmpty: text.isEmpty)
            var score = confidence
            // Head start (see `protected` above): momentum for the established
            // language, or the acoustic detection's pick while bootstrapping.
            // Whisper's English *translations* of Ukrainian speech decode
            // fluently (high confidence), so raw confidence alone would happily
            // flip the meeting into English.
            if mode == .final, let candidate, candidate == protected, !text.isEmpty {
                score += 0.2
            }
            if text.isEmpty, let dominant, candidate == dominant {
                dominantHeardNothing = true
            }
            if best == nil || score > best!.score {
                best = (text, score, confidence, candidate ?? results.first?.language)
            }
        }
        guard let best else { return "" }
        if candidates.count > 1 {
            log.notice("bilingual arbitration on \(source, privacy: .public): picked \(best.language ?? "?", privacy: .public) (score \(best.score, format: .fixed(precision: 2)), dominant \(dominant ?? "-", privacy: .public))")
        }

        // The language this source has spoken all session heard nothing here.
        // An empty decode is not a *worse* answer than a hallucinated one — for
        // audio carrying no real speech it is the right answer — but it scores
        // last, so any rival language that invents a word wins the arbitration
        // outright. That is how an English speaker's "mhm" came back as "М-м":
        // English correctly produced nothing, Ukrainian did not. Trust the
        // silence. A genuine language switch arrives as a full phrase, so it
        // still clears `establishesLanguage` and passes through untouched.
        if dominantHeardNothing, !best.text.isEmpty, best.language != dominant,
           !Self.establishesLanguage(best.text, confidence: best.confidence) {
            filteredSegments += 1
            log.notice("dropped invented \(best.language ?? "?", privacy: .public) on \(source, privacy: .public): dominant \(dominant ?? "-", privacy: .public) heard silence")
            return ""
        }

        // Drop a lone one/two-word line whose language contradicts what this
        // source has spoken all session: the stray "Дякую" (in an English
        // meeting) or "you"/"okay" (in a Ukrainian one) that survives the
        // acoustic gate as a confident hallucination. A real short answer is in
        // the stream's own language, and a genuine language switch arrives as a
        // full phrase — never a lone word — so bilingual switching is untouched.
        if let dominant, let lang = best.language, lang != dominant,
           Self.isShortFiller(best.text) {
            filteredSegments += 1
            log.notice("dropped cross-language filler on \(source, privacy: .public): \(lang, privacy: .public) vs dominant \(dominant, privacy: .public)")
            return ""
        }

        // Remember what this source actually speaks — but only from a line
        // long enough to *mean* something. Short outputs ("Дякую", "okay",
        // "you") are exactly what Whisper invents from silence; letting them
        // vote on language is how two hallucinations lock a stream into the
        // wrong language, after which every real line decodes as that
        // language's garbage and gets filtered away. Final passes are informed
        // (arbitrated) choices; in unrestricted auto any detection beats none.
        if mode == .final || (language == nil && allowedLanguages.isEmpty),
           let lang = best.language, !lang.isEmpty,
           allowedLanguages.isEmpty || allowedLanguages.contains(lang),
           Self.establishesLanguage(best.text, confidence: best.confidence) {
            detectedLanguage[source] = lang
            if mode == .final {
                languageTally[source, default: [:]][lang, default: 0] += 1
            }
        }
        return best.text
    }

    /// The language most of this source's final lines were in — needs at
    /// least two committed lines to count as established.
    private func dominantLanguage(for source: String) -> String? {
        guard let tally = languageTally[source],
              let leader = tally.max(by: { $0.value < $1.value }),
              leader.value >= 2 else { return nil }
        return leader.key
    }

    /// The language the meeting as a whole has settled on, across both sources.
    /// A call is overwhelmingly conducted in one language, so when a source has
    /// no momentum of its own — its first utterance, or a long run of "mhm"
    /// that never earned a vote — the *other* side's established language is
    /// far better evidence than a fixed default.
    private func sessionDominantLanguage() -> String? {
        var totals: [String: Int] = [:]
        for tally in languageTally.values {
            for (lang, count) in tally { totals[lang, default: 0] += count }
        }
        guard let leader = totals.max(by: { $0.value < $1.value }),
              leader.value >= 2 else { return nil }
        return leader.key
    }

    /// What to decode as when nothing about this utterance is certain: this
    /// source's own momentum, then the meeting's, and only then the allowed
    /// set's first entry. That last resort used to be the *only* rule, which
    /// meant every uncertain scrap of an all-English call was decoded as
    /// Ukrainian (the auto set leads with "uk") and came back as Cyrillic.
    private func fallbackLanguage(for source: String) -> String? {
        dominantLanguage(for: source) ?? sessionDominantLanguage() ?? allowedLanguages.first
    }

    /// Whether a line is solid enough evidence to set or reinforce a source's
    /// language. Word count alone was not enough: Whisper invents *fluent*
    /// four-word lines from an English speaker's backchannel ("Я думаю, це
    /// димитро", "Словляться і без мазу рух"), and those votes are what locked
    /// a stream into the wrong language, after which every real line decoded as
    /// that language's garbage. Three bars instead:
    ///   - enough words to carry a language at all;
    ///   - enough of them distinct and long enough to be words rather than
    ///     grunts — "І сі, ага. Ага. І сі, ага." is seven tokens of nothing;
    ///   - decoder confidence high enough that they were heard, not invented.
    static func establishesLanguage(_ text: String, confidence: Float) -> Bool {
        guard confidence >= languageVoteConfidence else { return false }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 4 else { return false }
        let substantial = Set(
            words.map { $0.lowercased().filter(\.isLetter) }.filter { $0.count >= 3 })
        return substantial.count >= 3
    }

    /// Mean decoder log-probability a line must beat before it may vote on
    /// language. Whisper's own "this decode is poor" bar is -1.0; a vote
    /// outlives the line it came from, so it is held to more.
    private static let languageVoteConfidence: Float = -0.7

    /// A lone one- or two-word output — the shape of a silence-hallucination
    /// ("Дякую", "you", "okay") rather than a real phrase.
    private static func isShortFiller(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return words > 0 && words <= 2
    }

    /// Token ids whose text contains letters Ukrainian never uses (ы э ъ ё).
    /// Built once per loaded model by scanning the vocabulary.
    private func russianMarkerTokens(pipe: WhisperKit) -> [Int] {
        if let cachedRussianMarkerTokens { return cachedRussianMarkerTokens }
        guard let tokenizer = pipe.tokenizer else { return [] }
        let markers = CharacterSet(charactersIn: "ыЫэЭъЪёЁ")
        var found: [Int] = []
        for id in 0..<tokenizer.specialTokens.specialTokenBegin {
            if tokenizer.decode(tokens: [id]).rangeOfCharacter(from: markers) != nil {
                found.append(id)
            }
        }
        cachedRussianMarkerTokens = found
        log.notice("Ukrainian decode guard: suppressing \(found.count) Russian-marker tokens")
        return found
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
        // Live previews reuse what the stream has settled on — cached detection,
        // then the dominant language (momentum) — so they don't pay for a
        // detection pass on every pass. Only when nothing is known yet (a fresh
        // source's first utterance) do we spend one detection pass, rather than a
        // blind Ukrainian-first default that would show an English speaker as
        // Cyrillic until a final corrects it; and we adopt it only when confident.
        guard mode == .final else {
            if let cached { return [cached] }
            if let dominant = dominantLanguage(for: source) { return [dominant] }
            guard allowedLanguages.count > 1,
                  let detection = try? await pipe.detectLangauge(audioArray: samples) else {
                return [fallbackLanguage(for: source)]
            }
            let ranked = allowedLanguages
                .map { (code: $0, prob: detection.langProbs[$0] ?? 0) }
                .sorted { $0.prob > $1.prob }
            let top = ranked[0]
            let certain = top.prob >= 0.85 || ranked[1].prob == 0 || top.prob >= 6 * ranked[1].prob
            // Not confident enough to cache — but an uncertain reading of this
            // audio still beats a blind default, and the meeting's own settled
            // language beats both.
            guard certain else {
                return [sessionDominantLanguage() ?? top.code]
            }
            detectedLanguage[source] = top.code   // confident enough to reuse
            return [top.code]
        }
        guard allowedLanguages.count > 1 else { return [allowedLanguages.first] }

        if let detection = try? await pipe.detectLangauge(audioArray: samples) {
            let ranked = allowedLanguages
                .map { (code: $0, prob: detection.langProbs[$0] ?? 0) }
                .sorted { $0.prob > $1.prob }
            let top = ranked[0], next = ranked[1]
            let dominant = dominantLanguage(for: source)
            let certain = top.prob >= 0.85 || next.prob == 0 || top.prob >= 6 * next.prob
            // Single-decode only to MAINTAIN an established language when a
            // near-certain detection agrees with it. While bootstrapping (no
            // dominant yet) NEVER trust one short-utterance detection: it
            // mislabels Ukrainian-accented English as Ukrainian and, in a short
            // meeting, locks every committed line into Cyrillic before momentum
            // can form. Decode both instead and let decode-score arbitration
            // pick — `transcribe` gives the detection's choice (returned first)
            // a +0.2 head start, so genuinely Ukrainian audio, whose English
            // translation also decodes fluently, still needs a decisively
            // better English decode to flip. Fixes short English meetings
            // without weakening the guard that keeps Ukrainian out of English.
            if let dominant, top.code == dominant, certain {
                return [dominant]
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
    /// most of the context window. The context is offered only to a candidate
    /// whose script it matches: an English-text prompt on a Ukrainian decode
    /// (or vice versa) drags the decoder toward the wrong language, which is
    /// how one bad line used to poison the rest of the meeting.
    private func promptTokens(for source: String, pipe: WhisperKit, decodingAs candidate: String?) -> [Int]? {
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
        if let context = recentContext[source], !context.isEmpty,
           Self.scriptCompatible(context, with: candidate) {
            tokens += tokenizer.encode(text: " " + context)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                .suffix(120)
        }
        return tokens.isEmpty ? nil : tokens
    }

    /// Whether text's script plausibly belongs to the language being decoded.
    private static func scriptCompatible(_ text: String, with candidate: String?) -> Bool {
        guard let candidate else { return true }
        var cyrillic = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            default: break
            }
        }
        switch candidate {
        case "uk", "ru": return cyrillic >= latin
        case "en": return latin >= cyrillic
        default: return true
        }
    }

    // MARK: - Output quality filters

    /// Drops segments the decoder itself marked as dubious: probable silence,
    /// degenerate repetition loops, and 1–2 word fragments born of near-silence
    /// (the "you" / "Thank you." / "Дякую" Whisper invents between utterances).
    /// A short fragment is junk when it is either low-confidence *or* comes with
    /// a high no-speech probability — the latter catches the confident-sounding
    /// hallucinations that slipped through the old confidence-only test, while
    /// a genuine one-word answer (real speech, low no-speech prob) still passes.
    /// Reasons are logged as metrics only — never transcript text — so tuning
    /// stays data-driven without spoken content leaving the app.
    private func trustworthy(_ segment: TranscriptionSegment) -> Bool {
        guard let reason = SegmentQuality.rejection(segment) else { return true }
        let words = segment.text.split(whereSeparator: { $0.isWhitespace }).count
        filteredSegments += 1
        log.notice("filtered segment #\(self.filteredSegments) (\(reason, privacy: .public)): words=\(words) noSpeech=\(segment.noSpeechProb, format: .fixed(precision: 2)) logprob=\(segment.avgLogprob, format: .fixed(precision: 2))")
        return false
    }

    private static func cleaned(_ raw: String) -> String {
        let text = SegmentQuality.stripped(raw)
        let normalized = AudioMonitor.normalizedForEcho(text)
        if normalized.isEmpty || SegmentQuality.hallucinationPhrases.contains(normalized) { return "" }
        return text
    }
}

/// Output-quality rules shared by the live transcriber and the offline
/// polisher. These existed as two hand-kept copies and had already drifted
/// once — a fix landed in one and left the other filtering by the old rules —
/// so both paths now read them from here.
enum SegmentQuality {
    /// Why this segment should be discarded, or nil to keep it. Reasons are
    /// returned rather than logged so callers can report them as metrics
    /// without spoken content ever leaving the app.
    ///
    /// Repetition needs two bars, not one. People really do talk in lists —
    /// "amount, date, accounts payable… amount, date, paid via" — and a flat
    /// compression-ratio cut discarded whole spoken requirements as if they
    /// were decoder loops. A stuck decoder is repetitive *and* unsure of
    /// itself, so moderate repetition goes only when confidence is also poor;
    /// past 3.6 the output is degenerate whatever the confidence claims.
    static func rejection(_ segment: TranscriptionSegment) -> String? {
        if segment.noSpeechProb > 0.8 && segment.avgLogprob < -0.7 { return "probable-silence" }
        if segment.noSpeechProb > 0.6 && segment.avgLogprob < -1.0 { return "weak-silence" }
        if segment.compressionRatio > 3.6 { return "degenerate-loop" }
        if segment.compressionRatio > 2.6 && segment.avgLogprob < -0.6 { return "repetition-loop" }
        let words = segment.text.split(whereSeparator: { $0.isWhitespace }).count
        if words > 0, words <= 2, segment.avgLogprob < -1.0 || segment.noSpeechProb > 0.6 {
            return "short-junk"
        }
        return nil
    }

    /// Stock phrases Whisper invents on near-silence (learned from YouTube
    /// outros). Compared against a *whole* normalized line, so a real
    /// "thank you" inside a sentence is never touched.
    static let hallucinationPhrases: Set<String> = [
        "thank you for watching", "thanks for watching", "subscribe to the channel",
        "please subscribe", "see you in the next video",
        "дякую за перегляд", "підписуйтесь на канал", "до зустрічі в наступному відео",
        "субтитри створені спільнотою amara org", "субтитри створював dimatorzok",
        "спасибо за просмотр", "продолжение следует", "субтитры сделал dimatorzok",
    ]

    /// Whisper wraps non-speech events in brackets: [музика], [applause], …
    /// Strips those and normalizes whitespace.
    static func stripped(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\[[^\]\n]{1,40}\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
