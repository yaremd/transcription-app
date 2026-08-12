import Foundation
import os
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
    /// Per source: how many final lines each language has produced this
    /// session. The leader is the source's "dominant" language — the momentum
    /// that keeps one noisy detection from flipping a Ukrainian meeting into
    /// English (which Whisper then *translates* into) or Russian.
    private var languageTally: [String: [String: Int]] = [:]
    /// Token ids containing letters Ukrainian never uses (ы э ъ ё) — cached
    /// per loaded model; suppressed whenever decoding as Ukrainian.
    private var cachedRussianMarkerTokens: [Int]?
    private var filteredSegments = 0       // junk dropped this session, for tuning
    /// Consecutive decodes this session that came back empty *with* the
    /// vocabulary prompt attached and had to be re-run without it, and whether
    /// we have given up on prompting for the rest of the session. See
    /// `promptIsWorthTrying`.
    private var promptedEmptyRun = 0
    private var promptAbandoned = false
    /// Memory coordination (tight-RAM Macs): whether a recording is currently
    /// using the speech model, and when it last ran — so the model is released
    /// for the notes model only when it's genuinely idle. See `releaseIfIdle`.
    private var recordingActive = false
    private var lastTranscribeAt = Date.distantPast
    /// Decodes currently inside the model. The idle clock alone was not enough:
    /// it was stamped at decode *start*, so one long decode looked like idleness
    /// and the model could be freed mid-decode — after which every utterance
    /// still queued on the commit chain silently transcribed to "".
    private var activeDecodes = 0
    /// Tail of the WhisperKit call queue. The actor suspends at every `await
    /// pipe…`, so live previews and both streams' final passes used to run
    /// *concurrently inside WhisperKit* — and once in a while one of those
    /// collisions never resumed. A commit chain awaiting that decode then
    /// starved silently and the stream stopped producing lines for the rest of
    /// the meeting (2026-07-29: the mic went quiet mid-test right after its
    /// live passes started overlapping a long final; same signature on the
    /// morning call's system stream). All model calls now run one at a time.
    private var pipeTail: Task<Void, Never>?
    private let log = Logger(subsystem: "com.yarem.Seal", category: "Transcriber")
    /// Diagnostic tap for the offline replay harness (SessionReplayTests): one
    /// line per decode decision, including transcript text. Nil in production —
    /// the only cost there is a nil check, and text never reaches the os_log.
    private var diagnostics: (@Sendable (String) -> Void)?

    func setDiagnostics(_ sink: (@Sendable (String) -> Void)?) { diagnostics = sink }

    /// Sets the custom vocabulary that biases transcription toward the user's
    /// names/jargon. Tokenized lazily on the next transcribe (it needs the loaded
    /// model's tokenizer). A decoder prompt, so it works in any language.
    func setVocabulary(_ terms: [String]) {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        vocabularyPrompt = cleaned.joined(separator: ", ")
        cachedVocabularyTokens = nil
        // A different term list is a different prompt, and may well survive
        // where the last one did not — see `promptIsWorthTrying`.
        promptedEmptyRun = 0
        promptAbandoned = false
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
        languageTally = [:]
        filteredSegments = 0
        promptedEmptyRun = 0
        promptAbandoned = false   // a new model or a new vocabulary may behave differently
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
        guard pipe != nil, !recordingActive, activeDecodes == 0,
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
                let loaded = try await WhisperKit(WhisperKitConfig(model: name, prewarm: true))
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

    /// `source` keys the auto-detected language ("You" may speak a different
    /// language than the call audio). Live passes skip everything optional so
    /// the preview keeps up; final passes spend more effort on accuracy — and
    /// may decode twice when the language is ambiguous.
    func transcribe(_ samples: [Float], source: String, mode: TranscribeMode) async -> String {
        guard let pipe, samples.count >= 1600 else { return "" }   // need ≥ 0.1s of audio
        // Measured before padding: `decodable` pads everything short up to
        // 1.1 s, which would erase exactly the distinction this is for.
        let audioSeconds = Double(samples.count) / 16_000
        let samples = Self.decodable(samples)
        lastTranscribeAt = Date()
        activeDecodes += 1
        // Completion re-stamps the idle clock: idleness is measured from when
        // the model finished working, not from when it last started.
        defer { activeDecodes -= 1; lastTranscribeAt = Date() }

        let (candidates, leadHasEvidence, detectedOutsideAllowedSet) = await languageCandidates(samples: samples, source: source, mode: mode, pipe: pipe)
        // Momentum the other side of the call contradicts is not momentum we
        // act on — see `momentumIsContested`. `dominant` stays visible for
        // logging and voting; it just stops steering the outcome.
        let established = dominantLanguage(for: source)
        let contested = momentumIsContested(for: source)
        let dominant = contested ? nil : established
        // The language arbitration gives a head start to the one it shouldn't
        // lightly abandon: the established dominant once momentum exists, or —
        // while still bootstrapping — the acoustic detection's pick, which
        // `languageCandidates` offers first (and only when it is real evidence,
        // not a list-order tie break). Without this, a short meeting has no
        // momentum yet and Whisper's fluent English translations of Ukrainian
        // would win on raw confidence alone.
        // Contested: nothing is protected. The bootstrap head start would
        // otherwise go to the acoustic detection's pick — and that detector is
        // the same signal that mislabelled this stream in the first place (it
        // hears Ukrainian-accented English as Ukrainian). The independent
        // evidence is the other stream, and it disagrees, so neither candidate
        // gets a thumb on the scale.
        var protected = contested
            ? nil
            : dominant ?? (leadHasEvidence && candidates.count > 1 ? (candidates.first ?? nil) : nil)
        if let p = protected, !candidates.contains(p) { protected = nil }
        diagnostics?("[\(source)] \(mode == .live ? "live" : "FINAL") audio=\(String(format: "%.1f", Double(samples.count) / 16_000))s candidates=[\(candidates.map { $0 ?? "auto" }.joined(separator: ","))] protected=\(protected ?? "-") dominant=\(dominant ?? "-")\(contested ? " CONTESTED (own \(established ?? "-") vs other \(otherSourceDominant(excluding: source)?.lang ?? "-"))" : "")")
        if contested {
            log.notice("momentum on \(source, privacy: .public) is contested: own \(established ?? "-", privacy: .public) vs better-established \(self.otherSourceDominant(excluding: source)?.lang ?? "-", privacy: .public) elsewhere — deciding on merit")
        }
        // The protected language decodes first, so every later candidate is
        // judged as a challenger against its result (see the evidence bar in
        // the loop). Matters when the dominant differs from the detection's
        // pick — the dominant is protected but was offered second.
        var ordered = candidates
        if let protected, let at = ordered.firstIndex(of: protected), at > 0 {
            ordered.remove(at: at)
            ordered.insert(protected, at: 0)
        }
        var best: (text: String, score: Float, confidence: Float, language: String?, scriptHonest: Bool)?
        /// Whether the language this source has been speaking all session heard
        /// nothing in this audio — see the silence check below.
        var dominantHeardNothing = false
        /// Same signal for the protected candidate while bootstrapping: the
        /// language the *detector* picked heard nothing here.
        var protectedHeardNothing = false
        /// How many candidate languages answered this audio with nothing but
        /// their own stock silence-word. See the corroborated-silence drop.
        var stockFillerCandidates = 0
        for candidate in ordered {
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
            // Only the custom vocabulary is prompted — never the running
            // transcript. See `promptTokens`.
            options.promptTokens = promptTokens(for: source, pipe: pipe)
            // No decode may be thrown away on its first predicted token.
            //
            // WhisperKit's `firstTokenLogProbThreshold` (−1.5 by default) ends
            // the decode loop the moment the model looks unsure of the token it
            // is about to sample, and returns `DecodingResult.emptyResults` —
            // text "", avgLogProb 0, noSpeechProb 0, compressionRatio 0. The
            // window is gone, and the all-zero stats make the loss look like a
            // decode that simply heard nothing. The temperature ladder cannot
            // rescue it either: a higher temperature flattens the distribution,
            // which *lowers* the first token's log-probability, so all three
            // rungs fail the same test.
            //
            // This was already disabled whenever a prompt was present, for a
            // sharper version of the same fault — WhisperKit skips its prefill
            // KV cache when prompted ("currently breaks if it starts at a
            // non-zero index"), leaving `prefilledIndex` at 0, so the bar was
            // tested against the first token of OUR prompt rather than the
            // first word of speech. But the unprompted path was left exposed,
            // and on real meeting audio it is just as destructive: in the
            // 2026-08-05 standup (Indian-accented English over conference
            // audio) it discarded 129 windows and six whole utterances —
            // 45.8 s of speech, 12% of everything decoded. The live pass
            // decoded one of those windows perfectly a fifth of a second
            // before the final pass abandoned it.
            //
            // Nothing is lost by removing it. Only voiced audio reaches the
            // decoder (the stream's own gate), and what comes back is judged by
            // `SegmentQuality.rejection` on real confidence, no-speech and
            // repetition numbers — which an aborted window never even produces.
            options.firstTokenLogProbThreshold = nil
            // Decoding as Ukrainian: ban every token containing a letter
            // Ukrainian never uses (ы э ъ ё) — Russian output becomes
            // impossible without touching legitimate Ukrainian text.
            if (candidate ?? language) == "uk" {
                options.supressTokens = russianMarkerTokens(pipe: pipe)
            }
            func decode(_ options: DecodingOptions) async -> [TranscriptionResult]? {
                do {
                    return try await serializedModelCall(timeout: 120) {
                        try await pipe.transcribe(audioArray: samples, decodeOptions: options)
                    }
                } catch {
                    // A decode failure used to vanish into a `try?` — a stream
                    // that errors on every pass looked exactly like one hearing
                    // silence.
                    log.error("decode as \(candidate ?? "auto", privacy: .public) failed on \(source, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    diagnostics?("[\(source)]   \(candidate ?? "auto"): DECODE THREW: \(error)")
                    return nil
                }
            }
            guard var results = await decode(options) else { continue }
            var all = results.flatMap { $0.segments }
            var kept = all.filter { trustworthy($0) }
            var text = Self.cleaned(kept.map { $0.text }.joined(separator: " "))
            // A prompted decode that produced nothing gets one unprompted retry.
            // Passing *any* prompt puts WhisperKit on a path where the decode
            // loop can end before it reaches the audio, and the whole window
            // then comes back empty rather than wrong — see `promptTokens`,
            // where this cost a meeting 86% of its far-side transcript. The
            // running transcript no longer goes into the prompt at all; this is
            // what keeps the custom vocabulary, which still does, from ever
            // costing a line. It runs only on the failure path.
            if text.isEmpty, options.promptTokens != nil {
                notePromptedDecodeWasEmpty()
                var unprompted = options
                unprompted.promptTokens = nil
                // `firstTokenLogProbThreshold` stays off here too. It used to
                // be restored to WhisperKit's default on this path, back when
                // it was only disabled *because* of the prompt; now that it is
                // off for every decode, restoring it would hand the retry the
                // same first-token bail the retry exists to escape.
                if let retried = await decode(unprompted) {
                    results = retried
                    all = results.flatMap { $0.segments }
                    kept = all.filter { trustworthy($0) }
                    text = Self.cleaned(kept.map { $0.text }.joined(separator: " "))
                    log.notice("retried \(candidate ?? "auto", privacy: .public) on \(source, privacy: .public) without the vocabulary prompt: \(text.isEmpty ? "still nothing" : "recovered", privacy: .public)")
                    diagnostics?("[\(source)]   \(candidate ?? "auto"): empty with a prompt, retried without -> \(text.isEmpty ? "still empty" : "\"\(text.prefix(60))\"")")
                }
            } else if !text.isEmpty, options.promptTokens != nil {
                promptedEmptyRun = 0   // the prompt is surviving on this audio
            }
            let confidence = Self.decodeScore(kept, isEmpty: text.isEmpty)
            var score = confidence
            // Whether this decode answered in a script the language we asked
            // for actually uses.
            //
            // `options.language` is a hint to Whisper, not a constraint. On
            // strongly non-English audio the `en` pass simply free-runs into
            // the language it hears — and its Cyrillic prior is Russian, the
            // best-resourced Slavic language it knows, not Ukrainian. Such a
            // decode is not an English reading of the audio at all; it is a
            // second opinion wearing English's label, and it collected
            // English's every privilege below.
            //
            // The 2026-08-07 lesson is the whole case in one number: twelve
            // Cyrillic lines, *all twelve* won by the `en` candidate, six of
            // them over a better-scoring `uk` candidate that the head start
            // alone reversed — "Придемо, придемо." (−0.35, correct) losing to
            // "- Придем, придем." (−0.76, Russian). The user's report was one
            // sentence: "російською я не говорив" — I did not speak Russian.
            let scriptHonest = !text.isEmpty && Self.scriptCompatible(text, with: candidate)
            // Head start (see `protected` above): momentum for the established
            // language, or the acoustic detection's pick while bootstrapping.
            // Whisper's English *translations* of Ukrainian speech decode
            // fluently (high confidence), so raw confidence alone would happily
            // flip the meeting into English. Withheld from a decode that
            // ignored its own language token: momentum is evidence about what
            // this source speaks, and a Cyrillic answer is not evidence for
            // English. (A real English translation of Ukrainian speech comes
            // back in Latin and still gets the head start — the hazard the
            // bonus exists for is untouched.)
            if mode == .final, let candidate, candidate == protected, scriptHonest {
                score += 0.2
            }
            if text.isEmpty, let dominant, candidate == dominant {
                dominantHeardNothing = true
            }
            if text.isEmpty, let protected, candidate == protected {
                protectedHeardNothing = true
            }
            if Self.isStockFiller(text) { stockFillerCandidates += 1 }
            let peakNoSpeech = all.map(\.noSpeechProb).max() ?? 0
            diagnostics?("[\(source)]   \(candidate ?? "auto"): conf=\(String(format: "%.2f", confidence)) score=\(String(format: "%.2f", score)) ns=\(String(format: "%.2f", peakNoSpeech)) kept=\(kept.count)/\(all.count)\(text.isEmpty || scriptHonest ? "" : " WRONG-SCRIPT") \"\(text.prefix(120))\"")
            // The evidence bar: a challenger may only displace the protected
            // language's real text with output solid enough to vote for its
            // own language. Junk that cannot even vote is not evidence against
            // the prior — it was how "share my screen", decoded poorly in
            // English (the detector's pick), still lost to a *fluent-looking*
            // Ukrainian invention on raw score. A genuine language switch is
            // establish-grade by definition, so it still passes.
            // A holder that ignored its own language token is not the protected
            // language's text, so it does not get to raise the protected
            // language's bar against the candidate that answered honestly. This
            // is the half of the fix the score alone cannot do: "Придемо,
            // придемо." is two words, so it can never clear
            // `establishesLanguage`, and it lost every one of these on standing
            // rather than on merit.
            let holderIsProtected = best != nil && !best!.text.isEmpty
                && best!.language == protected && best!.scriptHonest
            let challengerHasStanding = !holderIsProtected || candidate == protected
                || Self.establishesLanguage(text, confidence: confidence)
            // Script honesty ranks above score, because between an honest and a
            // dishonest decode the two scores are not measuring the same thing:
            // one is the model's fit to the language we asked for, the other its
            // fluency in whatever language it drifted into. Whisper's Ukrainian
            // is weak and its Russian is strong, so on Ukrainian speech the
            // dishonest reading wins that comparison on merit — the twelve lines
            // above sat within 0.01–0.41 of each other. Where both candidates
            // are honest (all ordinary audio) nothing changes: it is score, then
            // the head start, exactly as before.
            let outranksBest = best.map {
                Self.outranks(challengerScore: score, challengerHonest: scriptHonest,
                              holderScore: $0.score, holderHonest: $0.scriptHonest)
            } ?? true
            if challengerHasStanding, outranksBest {
                best = (text, score, confidence, candidate ?? results.first?.language, scriptHonest)
            } else if !challengerHasStanding, score > (best?.score ?? -Float.infinity) {
                diagnostics?("[\(source)]   \(candidate ?? "auto") outscored \(protected ?? "-") but lacks standing; keeping the prior")
            }
        }
        guard var best else { return "" }
        if candidates.count > 1 {
            log.notice("bilingual arbitration on \(source, privacy: .public): picked \(best.language ?? "?", privacy: .public) (score \(best.score, format: .fixed(precision: 2)), dominant \(dominant ?? "-", privacy: .public))")
        }

        // Whisper's output style is bistable: the same audio that decodes
        // cased and punctuated on one pass can come back as a lowercase,
        // unpunctuated run-on on the next — its transcript-register training
        // data showing through. The 2026-08-10 call committed two such
        // stretches (YAR-90), and its live passes seconds apart rendered the
        // same exchange both ways, so this is a coin the decode flips, not an
        // accuracy limit. No prompt is involved (the running transcript is
        // never prompted) and no temperature either (one instance was a live
        // pass, where the fallback ladder is off).
        //
        // The repair is one re-decode with timestamp tokens enabled — the
        // strongest style anchor the model has; timestamped decodes segment
        // the audio sentence by sentence and don't run on. We decode finals
        // without timestamps for speed, so this costs one extra pass only on
        // the rare window that actually came back degenerate, and the original
        // text stands unless the repair returns the normal register.
        if mode == .final, Self.isDegenerateStyle(best.text) {
            diagnostics?("[\(source)] STYLE REPAIR: final came back lowercase run-on — re-decoding with timestamps")
            var repair = DecodingOptions()
            repair.task = .transcribe
            repair.skipSpecialTokens = true
            repair.withoutTimestamps = false
            repair.suppressBlank = true
            repair.temperatureFallbackCount = 2
            repair.language = best.language
            repair.detectLanguage = false
            repair.firstTokenLogProbThreshold = nil
            if best.language == "uk" { repair.supressTokens = russianMarkerTokens(pipe: pipe) }
            let repaired = try? await serializedModelCall(timeout: 120) {
                try await pipe.transcribe(audioArray: samples, decodeOptions: repair)
            }
            if let repaired {
                let kept = repaired.flatMap { $0.segments }.filter { trustworthy($0) }
                let text = Self.cleaned(kept.map { $0.text }.joined(separator: " "))
                if !text.isEmpty, !Self.isDegenerateStyle(text) {
                    diagnostics?("[\(source)] STYLE REPAIR kept: \"\(text.prefix(100))\"")
                    best.text = text
                } else {
                    diagnostics?("[\(source)] STYLE REPAIR failed (\(text.isEmpty ? "empty" : "still degenerate")) — keeping the original")
                }
            } else {
                diagnostics?("[\(source)] STYLE REPAIR decode threw or timed out — keeping the original")
            }
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
            diagnostics?("[\(source)] DROP trust-the-silence: \"\(best.text.prefix(80))\"")
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
            diagnostics?("[\(source)] DROP cross-language filler: \"\(best.text.prefix(80))\"")
            return ""
        }

        // The bootstrap face of trust-the-silence: no momentum exists yet, but
        // the acoustic detection picked a language — and that language heard
        // *nothing* in this audio. A rival that "heard" something anyway must
        // have clearly heard it; Whisper invents fluent-looking phrases from
        // hard accented audio at middling confidence ("Я покажу, как я щадлю
        // на скринь." at -0.41 for English speech whose en decode was empty),
        // and one of those as an early line is how a meeting opens Cyrillic.
        // Real first utterances in the other language decode clearly and pass.
        // `established`, not `dominant`: this is a bootstrap rule, and a
        // contested stream is not bootstrapping — it has been producing lines
        // all along, we simply stopped trusting which language they were in.
        if established == nil, protectedHeardNothing, !best.text.isEmpty,
           best.language != protected, best.confidence < Self.clearlyHeard {
            filteredSegments += 1
            log.notice("dropped bootstrap invention on \(source, privacy: .public): detection's \(protected ?? "?", privacy: .public) heard silence")
            diagnostics?("[\(source)] DROP bootstrap trust-the-silence (\(best.language ?? "?") conf \(String(format: "%.2f", best.confidence))): \"\(best.text.prefix(60))\"")
            return ""
        }

        // And with no momentum *and* no usable detection, nothing at all
        // vouches for a lone one/two-word output — the filler shape Whisper
        // invents from noise ("Я біжу?"). A real one-word opener rides on the
        // next utterance's evidence; losing it costs almost nothing.
        if established == nil, !leadHasEvidence, Self.isShortFiller(best.text) {
            filteredSegments += 1
            log.notice("dropped unvouched bootstrap filler on \(source, privacy: .public)")
            diagnostics?("[\(source)] DROP unvouched bootstrap filler: \"\(best.text.prefix(40))\"")
            return ""
        }

        // The rule above has a blind spot the 2026-08-10 call fell through:
        // the *meeting's* settled language vouches for the lead (the other
        // side was speaking English all along), so `leadHasEvidence` is true —
        // but that vouches for which language should lead, not for this near
        // -silent window containing speech at all. Its own detector said the
        // opposite: a language we don't even transcribe ("is", Icelandic).
        // Out of that contradiction Whisper produced a rare-token invention,
        // "Kjöngslið", at -0.44 — the worst kept confidence of the session —
        // and it became the mic channel's entire transcript.
        //
        // Real speech does come out of out-of-set windows (see the NO VOTE
        // doctrine below), so this stacks every qualifier: still bootstrapping,
        // detector outside the set, lone word, and *below* the clearly-heard
        // bar that genuine short answers clear. Anything real it costs rides
        // back in on the next utterance's evidence.
        if Self.isOutOfSetLoneInvention(text: best.text, confidence: best.confidence,
                                        hasMomentum: established != nil,
                                        detectedOutsideAllowedSet: detectedOutsideAllowedSet) {
            filteredSegments += 1
            log.notice("dropped out-of-set lone invention on \(source, privacy: .public)")
            diagnostics?("[\(source)] DROP out-of-set lone invention (conf \(String(format: "%.2f", best.confidence))): \"\(best.text.prefix(40))\"")
            return ""
        }

        // A lone word whose script contradicts the language that decoded it:
        // "Дякую." emitted under an *English* language token, from keyboard
        // noise after a video ended (2026-07-29 afternoon report). Such a line
        // wears the dominant language's label, so the cross-language rule
        // above never sees it. A real short answer is written in its own
        // decode's script, and a genuine language switch arrives as a full
        // phrase through the uk candidate — so this ghost is never real, in
        // any momentum state.
        if Self.isScriptContradiction(best.text, language: best.language) {
            filteredSegments += 1
            log.notice("dropped wrong-script filler on \(source, privacy: .public): decoded as \(best.language ?? "?", privacy: .public)")
            diagnostics?("[\(source)] DROP wrong-script filler (\(best.language ?? "?")): \"\(best.text.prefix(40))\"")
            return ""
        }

        // Before any momentum exists the cross-language rule above has nothing
        // to compare against — and recording start is exactly where Whisper
        // meets its first near-silence (the join chime, a breath, the keyboard)
        // and invents its stock lone words. "Others: Дякую!" as line one of an
        // all-English call came through here. Real openers ("Hello.", "Hi.")
        // are not stock fillers and pass untouched; a real "Thank you." later
        // in the meeting has momentum behind it by then and is never touched.
        if Self.isBootstrapHallucination(best.text, hasMomentum: established != nil) {
            filteredSegments += 1
            log.notice("dropped bootstrap stock filler on \(source, privacy: .public)")
            diagnostics?("[\(source)] DROP bootstrap stock filler: \"\(best.text.prefix(40))\"")
            return ""
        }

        // The same stock words, once momentum has reopened the door to them,
        // but out of an utterance that barely contained any speech.
        //
        // Momentum reopens that door because people really do say "thank you",
        // and by then a plain word list cannot tell a real one from an invented
        // one. Duration can. The 2026-08-05 planning call put four "You: Thank
        // you." lines into a transcript where the user had said nothing at all,
        // and all four look identical in the log: an utterance the stream
        // committed on 0.3 s of voiced audio — the least that clears
        // `minVoicedSeconds` — decoded confidently (−0.14, no-speech 0.00) so
        // every quality gate waved it through, with the Ukrainian candidate
        // independently producing its own "Дякую." from the same silence.
        //
        // A spoken "Thank you." is most of a second of voice on its own, so the
        // duration test only ever fires on utterances too short to have held
        // one. The second test is the stronger of the two and needs no clock:
        // *both* languages answered with their own stock word — "Thank you."
        // out of the English decode and "Дякую." out of the Ukrainian one, from
        // the same audio. Two models independently reaching for their canonical
        // response to nothing is what nothing sounds like; real speech makes
        // them disagree. Every one of that call's four false thank-yous has
        // this signature, including the two the clock alone let through.
        if Self.isStockFiller(best.text),
           audioSeconds <= Self.silentUtteranceSeconds || stockFillerCandidates > 1 {
            filteredSegments += 1
            let why = stockFillerCandidates > 1 ? "every candidate answered with one" : "too short to hold one"
            log.notice("dropped stock filler on \(source, privacy: .public): \(why, privacy: .public)")
            diagnostics?(String(format: "[%@] DROP stock filler (%@, %.1fs of audio): \"%@\"",
                                source, why, audioSeconds, String(best.text.prefix(40))))
            return ""
        }

        // A third language was spoken. Neither candidate could have been right,
        // so the winner is only the better of two wrong answers — the last
        // thing that should teach this source what it speaks. The 2026-08-05
        // standup opened on a minute of Hindi small talk: the detector said so
        // plainly ("hi", then "ur", then "pt"), the `en` decode of one window
        // aborted on its first token, and the `uk` decode won by walkover with
        // "Та таані, граєм, я додавців. Та, хтось. Ти, га, галка." — ten
        // Cyrillic words, fluent enough to clear `establishesLanguage`, which
        // cast the only Ukrainian vote of an entirely English meeting and put
        // that line at the top of the transcript.
        //
        // The vote is all we take away. Dropping the line as well is tempting
        // and wrong: on short windows this detector reaches outside the allowed
        // set constantly, and in that same meeting its "de", "es" and "pt"
        // windows carried "Hello. Yes.", "Demetra?" and "Thank you." — real
        // speech, correctly transcribed. A vote outlives the line it came from,
        // so it is held to evidence the line itself never has to meet.
        // (One narrow carve-out lives above: a *lone word* from such a window,
        // before any momentum, below the clearly-heard bar — the "Kjöngslið"
        // shape — does get dropped. Every real example here clears that bar.)
        if detectedOutsideAllowedSet, !best.text.isEmpty {
            diagnostics?("[\(source)] NO VOTE: detector heard a language outside the allowed set")
        }
        // Remember what this source actually speaks — but only from a line
        // long enough to *mean* something. Short outputs ("Дякую", "okay",
        // "you") are exactly what Whisper invents from silence; letting them
        // vote on language is how two hallucinations lock a stream into the
        // wrong language, after which every real line decodes as that
        // language's garbage and gets filtered away. Final passes are informed
        // (arbitrated) choices; in unrestricted auto any detection beats none.
        //
        // The winner's own script has to back the label too. Where no honest
        // candidate existed to outrank it — a monolingual stream, where `en` is
        // the only thing on offer — a decode that free-ran into Cyrillic still
        // reaches this line, and its label is the one thing about it we know to
        // be wrong. On the 2026-08-07 lesson eight such lines voted `en` on
        // Ukrainian sentences, reinforcing the very momentum that was reading
        // them wrong.
        if mode == .final || (language == nil && allowedLanguages.isEmpty),
           best.scriptHonest,
           let lang = best.language,
           Self.castsLanguageVote(text: best.text, confidence: best.confidence, decodedAs: lang,
                                  allowed: allowedLanguages,
                                  detectedOutsideAllowedSet: detectedOutsideAllowedSet) {
            detectedLanguage[source] = lang
            if mode == .final {
                languageTally[source, default: [:]][lang, default: 0] += 1
                diagnostics?("[\(source)] VOTE \(lang) (tally \(languageTally[source] ?? [:]))")
            }
        }
        // Every candidate decoded to nothing. Not a failure and not a drop —
        // just an answer of "" — and it was the one outcome in the whole chain
        // that said nothing at all: the guards log, the throws log, this
        // returned through the same door as a good decode. A stream losing
        // utterances here is indistinguishable, from the logs, from a stream
        // hearing silence, which is exactly why the 2026-07-31 system-audio
        // dropout could not be read off a 64-minute session.
        if best.text.isEmpty {
            let seconds = Double(samples.count) / 16_000
            log.notice("empty decode on \(source, privacy: .public): no candidate produced text for \(seconds, format: .fixed(precision: 1))s of audio")
            diagnostics?(String(format: "[%@] EMPTY: %.1fs of audio, no candidate produced text", source, seconds))
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

    /// The strongest language another source has established, and how many
    /// votes back it. The other side of a call is independent evidence about
    /// what language the *conversation* is in: hallucination is per-channel
    /// (it follows one speaker's accent and mic), the conversation is shared.
    static func otherSourceDominant(excluding source: String,
                                    in tallies: [String: [String: Int]]) -> (lang: String, votes: Int)? {
        var best: (lang: String, votes: Int)?
        for (other, tally) in tallies where other != source {
            guard let leader = tally.max(by: { $0.value < $1.value }), leader.value >= 2 else { continue }
            if best == nil || leader.value > best!.votes { best = (leader.key, leader.value) }
        }
        return best
    }

    private func otherSourceDominant(excluding source: String) -> (lang: String, votes: Int)? {
        Self.otherSourceDominant(excluding: source, in: languageTally)
    }

    /// Whether this source's momentum is contradicted by a *better-established*
    /// dominant on the other side of the call.
    ///
    /// Momentum is a thumb on the scale — a head start plus the drop guards
    /// that delete anything in another language. That is right when the
    /// momentum is right, and catastrophic when it is not: on 2026-07-31 two
    /// early Ukrainian hallucinations locked an English speaker's mic stream
    /// into "uk", after which the guards deleted 98 real English lines and no
    /// English line could ever vote to correct it. Sixty minutes of English
    /// could not dislodge two bad votes, while the other stream sat at a clean,
    /// unanimous "en" the whole time.
    ///
    /// When contested we take the thumb off the scale — no head start, no
    /// momentum-keyed drops — and let the decode scores decide on merit. We do
    /// not force the other side's language: a genuinely bilingual call (one
    /// speaker Ukrainian, one English) still resolves correctly, because real
    /// Ukrainian speech decodes far better as `uk` than as `en` on its own.
    /// And the more a source has genuinely established its own language, the
    /// harder it is to contest — `>` means a well-evidenced stream is never
    /// second-guessed by a weaker one.
    static func momentumIsContested(for source: String, in tallies: [String: [String: Int]]) -> Bool {
        guard let tally = tallies[source],
              let leader = tally.max(by: { $0.value < $1.value }), leader.value >= 2,
              let other = otherSourceDominant(excluding: source, in: tallies) else { return false }
        return other.lang != leader.key && other.votes > leader.value && other.votes >= contestingVotes
    }

    private func momentumIsContested(for source: String) -> Bool {
        Self.momentumIsContested(for: source, in: languageTally)
    }

    /// How well-established the other side must be before it may contest this
    /// source's momentum. Two votes make a dominant; a dominant that overrides
    /// *another* dominant is held to more.
    static let contestingVotes = 3

    // MARK: - Giving up on the vocabulary prompt

    /// Whether the vocabulary is still worth attaching to a decode.
    ///
    /// A prompt costs nothing when it works and *doubles the decode* when it
    /// does not — every empty prompted pass is re-run unprompted. On the
    /// 2026-08-05 planning call, with two names in the vocabulary ("Dmytro",
    /// "Adi"), 1083 of 1197 decodes went down that path: nine passes in ten
    /// were done twice, and 75 times the retry came back empty as well and the
    /// utterance was lost. The names were not spelled right either.
    ///
    /// The mechanism is WhisperKit's. With `promptTokens` set it skips the
    /// prefill KV cache ("currently breaks if it starts at a non-zero index"),
    /// so the decode loop starts at index 0 and replays the prompt — and
    /// `isSegmentCompleted` tests `sampleResult.completed` on those replay
    /// passes too. A prompt the model reads as already finished, which a short
    /// term list very much is, ends the loop before it reaches the audio.
    ///
    /// So we try, and we stop trying. A run of failures this long is not bad
    /// luck on one window; it means the prompt does not survive this model.
    private var promptIsWorthTrying: Bool { !promptAbandoned }

    private func notePromptedDecodeWasEmpty() {
        guard !promptAbandoned else { return }
        promptedEmptyRun += 1
        guard promptedEmptyRun >= Self.promptFailureLimit else { return }
        promptAbandoned = true
        log.notice("the vocabulary prompt emptied \(Self.promptFailureLimit) decodes in a row — dropping it for the rest of this session so nothing decodes twice")
        diagnostics?("PROMPT ABANDONED after \(Self.promptFailureLimit) consecutive empty prompted decodes")
    }

    /// Consecutive empty prompted decodes before the prompt is abandoned. Low
    /// on purpose: the retry means each failure costs a whole extra decode, and
    /// a prompt that works does not fail three times running.
    static let promptFailureLimit = 3

    /// Whether a challenging decode should take the arbitration from the
    /// current holder. Script honesty first, score second.
    ///
    /// The ordering is not a tiebreak dressed up — the two scores are
    /// incommensurable. A decode that answered in the language we asked for is
    /// scored on its fit to that language; one that ignored the token is scored
    /// on its fluency in whatever it drifted into, and Whisper is far more
    /// fluent in Russian than in Ukrainian. Comparing them is why the correct
    /// "Придемо, придемо." (−0.35) read as the worse answer than the Russian
    /// "- Придем, придем." (−0.76). Between two honest decodes — every ordinary
    /// utterance — this is plain score, unchanged.
    static func outranks(challengerScore: Float, challengerHonest: Bool,
                         holderScore: Float, holderHonest: Bool) -> Bool {
        challengerHonest == holderHonest ? challengerScore > holderScore : challengerHonest
    }

    /// Whether a decoded line may teach a source what language it speaks: it
    /// must be solid enough to carry a language (`establishesLanguage`), be
    /// written in one we transcribe, and come from audio the detector did not
    /// name as some third language.
    static func castsLanguageVote(text: String, confidence: Float, decodedAs language: String,
                                  allowed: [String], detectedOutsideAllowedSet: Bool) -> Bool {
        guard !detectedOutsideAllowedSet, !language.isEmpty else { return false }
        guard allowed.isEmpty || allowed.contains(language) else { return false }
        return establishesLanguage(text, confidence: confidence)
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

    /// The bar for "clearly heard": what a rival language must reach to
    /// override the detection's pick having heard silence, while no momentum
    /// exists to judge by. Genuine speech in the rival language decodes above
    /// this; Whisper's fluent inventions from hard audio sit below it.
    static let clearlyHeard: Float = -0.35

    // MARK: - Decode input length

    /// Shortest array WhisperKit will actually decode, plus margin.
    ///
    /// Its decode loop is `while seek < audioArray.count - windowClipTime`,
    /// and `windowClipTime` defaults to one second (it exists to stop the
    /// model hallucinating off the end of a window). An array of a second or
    /// less therefore never enters the loop at all: no segments, no tokens, no
    /// error — `transcribe` returns "" and nothing anywhere says why. Our own
    /// gate was 0.1 s, ten times too permissive, so every "yes", "exactly" and
    /// "mhm" the stream cut cleanly was handed over and silently thrown away
    /// (9% of the system stream's utterances on the 2026-07-31 lesson, 15% of
    /// the mic's).
    static let minDecodeSamples = 17_600      // 1.1 s

    /// Pads a short utterance out to `minDecodeSamples` rather than refusing
    /// it. Whisper zero-pads every window to 30 s internally regardless, so
    /// trailing zeros leave the model's input byte-identical — they only get
    /// the audio past the loop's entry test.
    static func decodable(_ samples: [Float]) -> [Float] {
        guard samples.count < minDecodeSamples else { return samples }
        return samples + [Float](repeating: 0, count: minDecodeSamples - samples.count)
    }

    // MARK: - Model-call discipline

    struct DecodeTimeout: Error, LocalizedError {
        var errorDescription: String? { "the model call did not finish in time" }
    }

    /// Runs one WhisperKit call: strictly after every earlier one (FIFO), and
    /// never allowed to stall its caller past `timeout`. The serialization
    /// removes the concurrent-call overlap that intermittently never resumed;
    /// the timeout is the backstop for anything that still hangs — the caller
    /// gets an error and the commit chain keeps flowing, losing one utterance
    /// instead of every line after it.
    private func serializedModelCall<T>(timeout: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
        let previous = pipeTail
        let work = Task { () throws -> T in
            await previous?.value
            return try await op()
        }
        // Installed before any suspension, so callers queue in arrival order.
        pipeTail = Task { _ = try? await work.value }
        do {
            return try await Self.awaiting(work, upTo: timeout)
        } catch is DecodeTimeout {
            log.fault("model call stalled beyond \(timeout, format: .fixed(precision: 0))s — abandoning it so the stream keeps transcribing")
            work.cancel()
            // Unhook new arrivals from the wedged link — they'd inherit the
            // stall through the chain otherwise. Callers already queued behind
            // it each free themselves the same way this one just did.
            pipeTail = nil
            throw DecodeTimeout()
        }
    }

    /// Awaits `work`, giving up after `seconds`. A continuation resumed by
    /// whichever finishes first — deliberately not a task group, because
    /// awaiting a task's value never reacts to cancellation, so a genuinely
    /// hung call would hold a group (and with it the stream) hostage. The
    /// watcher task that stays behind on a hung call is the price of freeing
    /// the chain, and it costs nothing unless the call eventually returns.
    static func awaiting<T>(_ work: Task<T, Error>, upTo seconds: TimeInterval) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(with result: Result<T, Error>) {
                let mine = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if mine { cont.resume(with: result) }
            }
            Task {
                do { resumeOnce(with: .success(try await work.value)) }
                catch { resumeOnce(with: .failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                resumeOnce(with: .failure(DecodeTimeout()))
            }
        }
    }

    /// A lone one- or two-word output — the shape of a silence-hallucination
    /// ("Дякую", "you", "okay") rather than a real phrase.
    private static func isShortFiller(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return words > 0 && words <= 2
    }

    /// A short line written in a script its own decode language wouldn't use —
    /// Cyrillic out of an English decode, Latin out of a Ukrainian one. The
    /// hallucination shape that wears the *right* language label and so slips
    /// every cross-language guard.
    static func isScriptContradiction(_ text: String, language: String?) -> Bool {
        isShortFiller(text) && !scriptCompatible(text, with: language)
    }

    /// Whether a line is one of Whisper's stock lone-word silence inventions,
    /// caught in the only window where they can't be caught by language
    /// contradiction: before the source has any momentum. Unlike
    /// `SegmentQuality.hallucinationPhrases` these are words people genuinely
    /// say, so momentum reopens the door to them.
    static func isBootstrapHallucination(_ text: String, hasMomentum: Bool) -> Bool {
        guard !hasMomentum else { return false }
        return isStockFiller(text)
    }

    /// A lone stock word, in any momentum state — the shape without the
    /// bootstrap condition, so the duration rule can use it too.
    static func isStockFiller(_ text: String) -> Bool {
        isShortFiller(text) && stockFillers.contains(AudioMonitor.normalizedForEcho(text))
    }

    /// The degenerate register (YAR-90): a long stretch with no capitals and
    /// no punctuation at all — Whisper's transcript-style training data
    /// surfacing in place of its normal written register. Real dictation in
    /// either of this app's languages acquires a capital or a mark well before
    /// its eighth word; asking for both signals to be entirely absent over a
    /// stretch that long keeps every ordinary sentence, fragment, and
    /// non-Latin line out of the net.
    static func isDegenerateStyle(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 8 else { return false }
        guard !text.contains(where: { $0.isUppercase }) else { return false }
        let marks: Set<Character> = [".", ",", "!", "?", ";", ":", "…"]
        return !text.contains(where: { marks.contains($0) })
    }

    /// The "Kjöngslið" shape (YAR-91, 2026-08-10): a rare-token invention out
    /// of near-silence — not a stock phrase, so no list can name it. What
    /// gives it away is the stack of everything else: the channel has no
    /// momentum yet, the window's own detector heard a language outside the
    /// allowed set (its way of saying "this audio is neither of your
    /// languages"), the output is a lone word, and its confidence sits below
    /// the bar genuine short answers clear. All four together, and the word
    /// was invented, not heard.
    static func isOutOfSetLoneInvention(text: String, confidence: Float,
                                        hasMomentum: Bool,
                                        detectedOutsideAllowedSet: Bool) -> Bool {
        !hasMomentum && detectedOutsideAllowedSet
            && isShortFiller(text) && confidence < clearlyHeard
    }

    /// Longest utterance that can be called silence when all it produced was a
    /// stock word. The stream trims a commit to its voiced span plus 0.3 s of
    /// padding at each end, so this is roughly "under half a second of voice" —
    /// beneath the length of the words themselves.
    static let silentUtteranceSeconds = 1.0

    /// Lone words Whisper reliably invents from near-silence — the openings of
    /// its learned YouTube-outro phrases, in each language this app arbitrates.
    /// Deliberately excludes real conversation openers ("okay", "yeah", "hi").
    private static let stockFillers: Set<String> = [
        "you", "thank you", "thanks", "thank you very much", "bye", "bye bye",
        "дякую", "дякую вам", "будь ласка", "до побачення",
        "спасибо", "пока",
        // What Whisper labels music with when the bracket convention slips —
        // "[музика]" is stripped elsewhere, but the bare word sneaks through
        // when a recording opens on a soundtrack (2026-07-29 screenshot:
        // "Others: Music / Музика" as the first lines of a session).
        "music", "музика", "музыка",
    ]

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
    ///
    /// `leadHasEvidence` says whether the first candidate is backed by actual
    /// evidence (acoustic detection, or the source's/meeting's momentum) — only
    /// then does it deserve the arbitration head start. A lead that is merely
    /// first in the allowed list is a guess, and protecting a guess is how an
    /// out-of-set detection ("Indonesian") used to hand Ukrainian a head start
    /// over English audio.
    ///
    /// `detectedOutsideAllowedSet` says the detector named a third language
    /// outright — it heard neither of the ones we transcribe. Whatever the
    /// arbitration then picks is the better of two wrong answers, so the line
    /// may be kept but must never vote on what this source speaks.
    private func languageCandidates(samples: [Float], source: String, mode: TranscribeMode, pipe: WhisperKit) async -> (candidates: [String?], leadHasEvidence: Bool, detectedOutsideAllowedSet: Bool) {
        if let language { return ([language], true, false) }
        // Contested momentum must not shortcut the decision anywhere: both the
        // cached detection and the dominant below can each return a *single*
        // candidate, and a single candidate means no arbitration runs at all.
        // That is the path that would have kept the 2026-07-31 lock-in alive —
        // the detector agrees with the wrong dominant (it mislabels accented
        // English exactly the way the stream already did), so `en` would never
        // be decoded to compare against.
        let contested = momentumIsContested(for: source)
        let cached = contested ? nil : detectedLanguage[source]
        if allowedLanguages.isEmpty { return ([cached], true, false) }  // unrestricted auto
        // Live previews reuse what the stream has settled on — cached detection,
        // then the dominant language (momentum) — so they don't pay for a
        // detection pass on every pass. Only when nothing is known yet (a fresh
        // source's first utterance) do we spend one detection pass, rather than a
        // blind Ukrainian-first default that would show an English speaker as
        // Cyrillic until a final corrects it; and we adopt it only when confident.
        guard mode == .final else {
            if let cached { return ([cached], true, false) }
            if !contested, let dominant = dominantLanguage(for: source) { return ([dominant], true, false) }
            guard allowedLanguages.count > 1,
                  let detection = try? await serializedModelCall(timeout: 30, { try await pipe.detectLangauge(audioArray: samples) }),
                  let top = Self.interpretDetection(detection, allowed: allowedLanguages) else {
                return ([fallbackLanguage(for: source)], true, false)
            }
            // Not confident enough to cache — but an uncertain reading of this
            // audio still beats a blind default, and the meeting's own settled
            // language beats both.
            guard top.prob >= Self.detectionCertainty else {
                return ([sessionDominantLanguage() ?? top.code], true, false)
            }
            detectedLanguage[source] = top.code   // confident enough to reuse
            diagnostics?("[\(source)] live-detect cached \(top.code) (p=\(String(format: "%.2f", top.prob)))")
            return ([top.code], true, false)
        }
        guard allowedLanguages.count > 1 else { return ([allowedLanguages.first], true, false) }

        let detection = try? await serializedModelCall(timeout: 30, { try await pipe.detectLangauge(audioArray: samples) })
        let dominant = contested ? nil : dominantLanguage(for: source)
        let top = detection.flatMap { Self.interpretDetection($0, allowed: allowedLanguages) }
        if let detection {
            // Formatted from `top` rather than through a `?? -1` sentinel: a
            // nil-coalesced Float lands in the variadic `%f` slot wrong and
            // printed every out-of-set detection as "p=nan", which reads like a
            // NaN probability the code had swallowed rather than "the detector
            // named a language you don't transcribe".
            let shown = top.map { String(format: "%.2f", $0.prob) } ?? "outside-allowed-set"
            diagnostics?("[\(source)] detect: \(detection.language) p=\(shown) inAllowed=\(top != nil)")
        }
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
        if let top, let dominant, top.code == dominant, top.prob >= Self.detectionCertainty {
            return ([dominant], true, false)
        }
        // The detection's pick leads and carries the bootstrap head start.
        // When the detector picked outside the allowed set (or failed), the
        // meeting's own settled language leads instead; with no momentum
        // either, the allowed list's order breaks the tie — but a mere tie
        // break has earned no head start.
        let momentum = dominant ?? sessionDominantLanguage()
        let lead = top?.code ?? momentum ?? allowedLanguages[0]
        let second = allowedLanguages.first { $0 != lead }
        let candidates = second.map { [lead, $0] } ?? [lead]
        // A detection that landed outside the allowed set is not a failed
        // reading — it is a successful one we have no candidate for.
        return (candidates, top != nil || momentum != nil, detection != nil && top == nil)
    }

    /// Decodes WhisperKit's language-detection result. Its `langProbs` carries
    /// exactly ONE entry — the winning language, valued with the LOG of its
    /// probability — and nothing for any other language. The old code read
    /// absent languages as "probability 0", which sorts ABOVE every real
    /// (negative) log value: detection came back inverted, ranking first the
    /// language it had NOT picked, and the 6×-ratio certainty test was always
    /// true against a negative number. That inversion handed the arbitration
    /// head start to the wrong language on every utterance of the 2026-07-29
    /// call — the "app missed almost everything" report.
    ///
    /// Returns the detector's pick as a true probability, or nil when it picked
    /// a language outside the allowed set (no usable signal).
    static func interpretDetection(
        _ detection: (language: String, langProbs: [String: Float]),
        allowed: [String]
    ) -> (code: String, prob: Float)? {
        guard allowed.contains(detection.language) else { return nil }
        // A missing *or non-finite* probability means the same thing: the pick
        // may still order the candidates, but nothing may be acted on alone.
        // `isFinite` matters more than it looks — `min(0, .nan)` is 0 in Swift
        // (the comparison is false, so it returns the first argument), so a NaN
        // read as a log-probability came out of `exp` as 1.0: a malformed
        // reading wearing perfect certainty, well clear of `detectionCertainty`
        // and enough to skip the second decode entirely.
        guard let logProb = detection.langProbs[detection.language], logProb.isFinite else {
            return (detection.language, 0)   // pick usable, confidence unknown
        }
        return (detection.language, exp(min(0, logProb)))
    }

    /// Detection probability above which a single reading may be acted on
    /// alone: cached for live passes, or trusted to skip the second decode
    /// when it agrees with the established dominant.
    static let detectionCertainty: Float = 0.85

    /// Mean decoder confidence of the kept segments; empty output ranks last.
    private static func decodeScore(_ segments: [TranscriptionSegment], isEmpty: Bool) -> Float {
        guard !isEmpty, !segments.isEmpty else { return -10 }
        let total = segments.reduce(Float(0)) { $0 + $1.avgLogprob }
        return total / Float(segments.count)
    }

    // MARK: - Decoder prompt

    /// The custom vocabulary, as prompt tokens. Capped well under Whisper's
    /// 224-token prompt budget so the audio keeps most of the context window.
    ///
    /// This used to carry the source's recent transcript too, so names kept
    /// their spelling and sentences continued naturally. It cost far more than
    /// it bought. Replaying the 2026-07-31 lesson through this exact code, the
    /// only difference being whether committed lines came back as prompt
    /// tokens, over the same twenty minutes:
    ///
    ///           with the transcript prompt   without
    ///   Others         11 utterances              97
    ///                   1 491 characters       11 018
    ///   empty decodes           150                 1
    ///   mic language     locked to uk        clean en
    ///
    /// Both of that meeting's symptoms were this: the far side losing 39
    /// minutes of clean speech, and the mic locking into Ukrainian (87 of its
    /// 126 lines came back Cyrillic). The mechanism is that WhisperKit checks
    /// `sampleResult.completed` on every pass of its decode loop, including the
    /// passes that only replay a prompt into the decoder — and those passes
    /// discard the model's prediction anyway, since the prompt token is forced.
    /// A prompt that reads like a finished sentence, which is exactly what a
    /// committed line is, makes the model answer `<|endoftext|>`; the loop ends
    /// before it reaches the audio and the window comes back empty. The
    /// suppression that should prevent this (`DecodingOptions.suppressBlank`)
    /// never fires: `SuppressBlankFilter` acts only when `tokens.count ==
    /// sampleBegin`, and `sampleBegin` is the prefill *cache* length, a number
    /// that is never equal to the count it is compared against. Restoring that
    /// suppression from outside was tried and did not bring the lines back.
    ///
    /// The vocabulary is a term list rather than a sentence, so it does not
    /// invite an `<|endoftext|>` the same way — and an empty prompted decode is
    /// retried without the prompt (see `transcribe`), so it cannot cost a line
    /// even if it ever does.
    private func promptTokens(for source: String, pipe: WhisperKit) -> [Int]? {
        guard promptIsWorthTrying, let tokenizer = pipe.tokenizer, !vocabularyPrompt.isEmpty else { return nil }
        if cachedVocabularyTokens == nil {
            cachedVocabularyTokens = Array(
                tokenizer.encode(text: " " + vocabularyPrompt)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                    .prefix(80))
        }
        let tokens = cachedVocabularyTokens ?? []
        return tokens.isEmpty ? nil : tokens
    }

    /// Whether text's script plausibly belongs to the language being decoded.
    ///
    /// Every *letter* is counted, and a third bucket holds the ones that are
    /// neither Latin nor Cyrillic. Without it a script no candidate language
    /// uses read as compatible with all of them — both counters stayed at zero,
    /// and `latin >= cyrillic` waved through the "うん" a Ukrainian speaker's
    /// backchannel produced under an English token (2026-08-07 lesson), along
    /// with every Hangul and CJK outro phrase Whisper reaches for near silence.
    static func scriptCompatible(_ text: String, with candidate: String?) -> Bool {
        guard let candidate else { return true }
        var cyrillic = 0, latin = 0, other = 0
        for scalar in text.unicodeScalars where Character(scalar).isLetter {
            switch scalar.value {
            // Cyrillic, plus the Cyrillic Supplement block.
            case 0x0400...0x052F: cyrillic += 1
            // ASCII letters, plus accented Latin (Latin-1 Supplement through
            // Latin Extended-B) so "ça" and "Schön" stay Latin.
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: latin += 1
            default: other += 1
            }
        }
        switch candidate {
        case "uk", "ru": return cyrillic >= latin && cyrillic >= other
        case "en": return latin >= cyrillic && latin >= other
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
        diagnostics?("    seg-drop \(reason) noSpeech=\(String(format: "%.2f", segment.noSpeechProb)) logprob=\(String(format: "%.2f", segment.avgLogprob)) cr=\(String(format: "%.2f", segment.compressionRatio)) \"\(segment.text.prefix(80))\"")
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
        // A segment carrying no words at all. Every rule below is written in
        // terms of the words there are, so a wordless segment used to satisfy
        // all of them and be *kept* — the decoder returned one segment, the
        // filter approved it, and the joined text was "". That is what a
        // decode aborted before it sampled anything looks like, and naming it
        // here is what makes it countable instead of silent.
        if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty-segment" }
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
