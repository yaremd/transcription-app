import XCTest
import WhisperKit
@testable import Seal

/// Regression tests for the transcript defects found by recording one call in
/// Seal and in Granola side by side (an all-English product review, July 2026).
/// Every string below is real output from that session, so these lock in the
/// specific failures rather than a theory of them.
final class TranscriptQualityTests: XCTestCase {

    // MARK: - Language votes

    /// The heart of the Cyrillic problem: an English speaker's backchannels
    /// came back as fluent-looking Ukrainian, and because they cleared a plain
    /// four-word count they *voted* on the stream's language. Two such votes
    /// establish a dominant, after which real English decoded as Ukrainian
    /// garbage. None of these may vote again.
    func testInventedBackchannelsCannotVoteOnLanguage() {
        let invented = [
            "М-м. Я, я си.",                 // four tokens, no word over two letters
            "І сі, ага. Ага. І сі, ага.",    // seven tokens, two distinct stems
            "Ви асш. Кінець.",
            "Клад із нього. Треба.",
            "Я думаю, це димитро.",
        ]
        for text in invented {
            XCTAssertFalse(
                Transcriber.establishesLanguage(text, confidence: -0.9),
                "\"\(text)\" must not establish a language at hallucination-grade confidence")
        }
    }

    /// The gate must not swing so far that real speech stops voting — that
    /// would leave every stream without momentum and reopen the original bug
    /// from the other side.
    func testRealSpeechStillVotes() {
        let real = [
            "I need to know the source of this",
            "Please, in this filter, add one filter to say AI expense",
            "So when due date is different from date, we just need to show it",
            "Дякую, що показали цей звіт, дуже корисно",
        ]
        for text in real {
            XCTAssertTrue(
                Transcriber.establishesLanguage(text, confidence: -0.35),
                "\"\(text)\" is a real phrase and must be allowed to vote")
        }
    }

    // MARK: - Contested momentum (2026-07-31 English lesson)

    /// The failure this rule exists for. An English lesson, 64 minutes: the
    /// system stream sat at a clean unanimous "en" from a native speaker, while
    /// two early Ukrainian hallucinations locked the mic stream into "uk". The
    /// momentum guards then deleted 98 real English lines, so English could
    /// never vote to correct it. The better-established other side must be able
    /// to reopen the question.
    func testAWeaklyHeldDominantIsContestedByTheOtherStream() {
        let tallies = ["You": ["uk": 2, "en": 1], "Others": ["en": 34]]
        XCTAssertTrue(Transcriber.momentumIsContested(for: "You", in: tallies),
                      "the mic stream's 2 uk votes must not outrank 34 clean en votes on the other stream")
        XCTAssertFalse(Transcriber.momentumIsContested(for: "Others", in: tallies),
                       "the well-established stream is the one doing the contesting, never the contested one")
    }

    /// The limit that keeps genuine bilingual calls working: a stream that has
    /// really established its own language outweighs the other side. This user
    /// does hold Ukrainian-and-English calls, and a Ukrainian speaker talking
    /// to an English speaker must stay Ukrainian.
    func testAWellEstablishedDominantIsNotContested() {
        let bilingual = ["You": ["uk": 40], "Others": ["en": 34]]
        XCTAssertFalse(Transcriber.momentumIsContested(for: "You", in: bilingual),
                       "40 Ukrainian votes are this speaker's own language, not a hallucination")
    }

    /// A dominant may only be contested by one that is *better* evidenced —
    /// equal footing is not enough to take the thumb off the scale.
    func testAnEquallyEvidencedDominantDoesNotContest() {
        let tied = ["You": ["uk": 5], "Others": ["en": 5]]
        XCTAssertFalse(Transcriber.momentumIsContested(for: "You", in: tied))
    }

    /// Two votes make a dominant; overriding another dominant is held to more,
    /// so a barely-established other side cannot reopen a settled stream.
    func testABarelyEstablishedOtherStreamCannotContest() {
        let thin = ["You": ["uk": 2], "Others": ["en": 2]]
        XCTAssertFalse(Transcriber.momentumIsContested(for: "You", in: thin),
                       "\(Transcriber.contestingVotes) votes are required to contest, and ties never contest")
    }

    /// Agreement is not a contest. Both streams in the same language must leave
    /// momentum fully intact — this is the common case and the guards that
    /// keep Ukrainian meetings Ukrainian all hang off it.
    func testAgreeingStreamsNeverContestEachOther() {
        let agreed = ["You": ["uk": 3], "Others": ["uk": 30]]
        XCTAssertFalse(Transcriber.momentumIsContested(for: "You", in: agreed))
        XCTAssertFalse(Transcriber.momentumIsContested(for: "Others", in: agreed))
    }

    /// A lone stream has no witness — nothing to contest it, whatever it says.
    func testASingleStreamIsNeverContested() {
        XCTAssertFalse(Transcriber.momentumIsContested(for: "You", in: ["You": ["uk": 9]]))
        XCTAssertFalse(Transcriber.momentumIsContested(for: "You", in: [:]))
    }

    /// The witness must itself be established: a single stray vote elsewhere is
    /// not evidence about the language of the call.
    func testAnUnestablishedOtherStreamIsNotAWitness() {
        XCTAssertNil(Transcriber.otherSourceDominant(excluding: "You",
                                                     in: ["You": ["uk": 2], "Others": ["en": 1]]))
    }

    /// Confidence is an independent bar: even well-formed text that the decoder
    /// itself was unsure of is not evidence of a language.
    func testLowConfidenceNeverVotes() {
        XCTAssertFalse(
            Transcriber.establishesLanguage("Словляться і без мазу рух.", confidence: -1.2))
        XCTAssertTrue(
            Transcriber.establishesLanguage("Словляться і без мазу рух.", confidence: -0.2),
            "the same text heard clearly is a genuine language switch")
    }

    // MARK: - Segment quality

    private func segment(_ text: String, logprob: Float = -0.3,
                         compression: Float = 1.8, noSpeech: Float = 0.05) -> TranscriptionSegment {
        TranscriptionSegment(text: text, avgLogprob: logprob,
                             compressionRatio: compression, noSpeechProb: noSpeech)
    }

    /// The largest single loss in the recording: ~45 words specifying how a
    /// payment row should render, discarded as a "repetition-loop" because
    /// people really do talk in lists. Repetitive *and* confident is speech.
    func testConfidentListySpeechSurvives() {
        let spoken = "amount, date, accounts payable, and then if it has another payment, "
            + "you put it below. Date paid via. So it's part of the row."
        XCTAssertNil(
            SegmentQuality.rejection(segment(spoken, logprob: -0.25, compression: 3.1)),
            "confident repetitive speech is a list, not a decoder loop")
    }

    /// A genuinely stuck decoder is repetitive *and* unsure, and past 3.6 the
    /// output is degenerate whatever the confidence claims.
    func testDecoderLoopsAreStillDropped() {
        XCTAssertEqual(
            SegmentQuality.rejection(segment("yes yes yes yes yes", logprob: -0.9, compression: 3.1)),
            "repetition-loop")
        XCTAssertEqual(
            SegmentQuality.rejection(segment("ha ha ha ha ha ha ha", logprob: -0.1, compression: 4.2)),
            "degenerate-loop")
    }

    /// The shape of the 2026-07-31 system-audio dropout: WhisperKit aborted the
    /// decode before sampling a single word and handed back one segment holding
    /// nothing but special tokens. Every other rule here is phrased in terms of
    /// the words a segment has, so a segment with none satisfied all of them and
    /// was *kept* — the decoder "succeeded", the filter approved it, the joined
    /// text was "", and 39 minutes of a lesson vanished without one log line.
    func testWordlessSegmentsAreRejectedRatherThanKept() {
        XCTAssertEqual(SegmentQuality.rejection(segment("")), "empty-segment")
        XCTAssertEqual(SegmentQuality.rejection(segment("   ")), "empty-segment")
        XCTAssertNil(SegmentQuality.rejection(segment("Yes, it is.")),
                     "a real short answer still carries words and must survive")
    }

    func testSilenceAndShortJunkAreStillDropped() {
        XCTAssertEqual(SegmentQuality.rejection(segment("Дякую", logprob: -0.9, noSpeech: 0.9)),
                       "probable-silence")
        XCTAssertEqual(SegmentQuality.rejection(segment("you", logprob: -1.4)), "short-junk")
        XCTAssertNil(SegmentQuality.rejection(segment("Okay.", logprob: -0.3)),
                     "a real one-word answer carries speech and must survive")
    }

    // MARK: - Decode input length

    /// WhisperKit's decode loop is `while seek < audioArray.count -
    /// windowClipTime`, and `windowClipTime` is one second by default — so an
    /// array of a second or less never enters it and comes back with no
    /// segments, no tokens and no error. The stream cuts short utterances all
    /// the time ("Yes, it is.", "Okay, any questions?"), and every one of them
    /// under a second was handed over and silently discarded: 9% of the system
    /// stream's utterances on the 2026-07-31 lesson, 15% of the mic's.
    func testShortUtterancesAreLongEnoughToDecode() {
        for seconds in [0.31, 0.5, 0.9, 1.0] {
            let padded = Transcriber.decodable([Float](repeating: 0.05, count: Int(seconds * 16_000)))
            XCTAssertGreaterThan(
                padded.count, 16_000,
                "\(seconds)s of audio must be padded past WhisperKit's one-second window gate")
        }
    }

    /// Padding is only ever added, never substituted for audio: the speech
    /// itself must reach the model untouched, and anything already long enough
    /// must not be copied at all.
    func testPaddingPreservesTheAudioAndLeavesLongUtterancesAlone() {
        let short = (0..<8_000).map { Float($0) / 8_000 }
        let padded = Transcriber.decodable(short)
        XCTAssertEqual(Array(padded.prefix(short.count)), short, "the speech must survive verbatim")
        XCTAssertTrue(padded.dropFirst(short.count).allSatisfy { $0 == 0 },
                      "the padding must be silence, not repeated audio")

        let long = [Float](repeating: 0.05, count: 16_000 * 5)
        XCTAssertEqual(Transcriber.decodable(long).count, long.count)
    }

    // MARK: - Language detection interpretation

    /// The 2026-07-29 "missed almost everything" call. WhisperKit's language
    /// detection returns ONLY the winning language, valued with the LOG of its
    /// probability; every other language is absent. Reading absent languages
    /// as "probability 0" ranked them ABOVE the real (negative) log value —
    /// detection came back inverted, "certainly" the language it had NOT
    /// picked, and the wrong language carried the arbitration head start on
    /// every utterance of the meeting.
    func testDetectionIsNotInvertedByAbsentLanguages() {
        let top = Transcriber.interpretDetection(
            (language: "en", langProbs: ["en": -0.27]),   // real result from that call
            allowed: ["uk", "en"])
        XCTAssertEqual(top?.code, "en", "the detector picked English; the code must not prefer Ukrainian")
        XCTAssertEqual(top?.prob ?? 0, exp(-0.27), accuracy: 0.001)
    }

    /// A pick outside the allowed set (Whisper mis-hearing accented speech as
    /// Malay, say) carries no usable signal about the allowed languages.
    func testDetectionOutsideAllowedSetIsUnusable() {
        XCTAssertNil(Transcriber.interpretDetection(
            (language: "ms", langProbs: ["ms": -0.1]), allowed: ["uk", "en"]))
    }

    /// Malformed result (no probability for its own pick): the pick is still
    /// usable for ordering, but must never clear the act-on-it-alone bar.
    func testDetectionWithoutAProbabilityIsNeverCertain() {
        let top = Transcriber.interpretDetection(
            (language: "uk", langProbs: [:]), allowed: ["uk", "en"])
        XCTAssertEqual(top?.code, "uk")
        XCTAssertLessThan(top?.prob ?? 1, Transcriber.detectionCertainty)
    }

    /// And a genuinely confident reading still clears it — the fast paths
    /// (live caching, single-decode with the dominant) must stay reachable.
    func testConfidentDetectionClearsTheCertaintyBar() {
        let top = Transcriber.interpretDetection(
            (language: "uk", langProbs: ["uk": -0.05]), allowed: ["uk", "en"])
        XCTAssertGreaterThanOrEqual(top?.prob ?? 0, Transcriber.detectionCertainty)
    }

    /// The polisher had the same inverted read (`langProbs[$0] ?? 0` inside a
    /// max-by): an English meeting would "Improve transcript" itself into
    /// forced-Ukrainian. When detection is unusable it now falls back to the
    /// script the live transcript is actually written in.
    func testPolisherFallsBackToTheTranscriptsOwnScript() {
        let english = [StoredLine(speaker: "You", text: "we ship the login flow tomorrow")]
        XCTAssertEqual(TranscriptPolisher.scriptMajorityLanguage(of: english, allowed: ["uk", "en"]), "en")
        let ukrainian = [StoredLine(speaker: "You", text: "завтра відвантажуємо логін-флоу")]
        XCTAssertEqual(TranscriptPolisher.scriptMajorityLanguage(of: ukrainian, allowed: ["uk", "en"]), "uk")
        XCTAssertNil(TranscriptPolisher.scriptMajorityLanguage(of: [], allowed: ["uk", "en"]),
                     "an empty transcript is evidence of nothing")
    }

    // MARK: - Input-device choice

    /// Whatever this machine's devices are, the wired-mic fallback must never
    /// itself pick a Bluetooth device — that would recreate the telephony-
    /// profile downgrade it exists to avoid (AirPods playback went unlistenable
    /// whenever recording was on, 2026-07-29).
    func testPreferredWiredInputIsNeverBluetooth() {
        guard let wired = MicCapturer.preferredWiredInput() else { return }   // headless rig: nothing to check
        XCTAssertFalse(MicCapturer.isBluetooth(wired.id),
                       "\(wired.name) was chosen as the wired fallback but is Bluetooth")
        XCTAssertFalse(wired.name.isEmpty)
    }

    // MARK: - Model-call timeout

    /// A hung model call must free its caller: the 2026-07-29 test session's
    /// mic stream stopped mid-recording because one decode never resumed and
    /// the commit chain starved behind it, silently, forever.
    func testAHungCallFreesItsCallerAfterTheTimeout() async {
        let hung = Task<Int, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return 1
        }
        do {
            _ = try await Transcriber.awaiting(hung, upTo: 0.2)
            XCTFail("a hung call must not return")
        } catch {
            XCTAssertTrue(error is Transcriber.DecodeTimeout)
        }
        hung.cancel()
    }

    /// …and a call that finishes in time passes its result through untouched.
    func testAHealthyCallReturnsItsResult() async throws {
        let quick = Task<Int, Error> { 42 }
        let value = try await Transcriber.awaiting(quick, upTo: 5)
        XCTAssertEqual(value, 42)
    }

    /// Errors from the call itself must surface as themselves, not as timeouts.
    func testACallsOwnErrorSurvivesTheRace() async {
        struct Boom: Error {}
        let failing = Task<Int, Error> { throw Boom() }
        do {
            _ = try await Transcriber.awaiting(failing, upTo: 5)
            XCTFail("the call's error must propagate")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    // MARK: - Wrong-script lone words

    /// The 2026-07-29 afternoon report: after a video ended, keyboard noise
    /// decoded — under the *English* language token — as "Дякую." twice. The
    /// line carried language=en, matched the dominant, and slipped every
    /// cross-language rule. A short line whose script contradicts its own
    /// decode language is never real.
    func testWrongScriptLoneWordsAreContradictions() {
        XCTAssertTrue(Transcriber.isScriptContradiction("Дякую.", language: "en"))
        XCTAssertTrue(Transcriber.isScriptContradiction("Дякую. М-м.", language: "en"))
        XCTAssertTrue(Transcriber.isScriptContradiction("okay", language: "uk"))
    }

    /// Same-script short answers and full phrases are untouched — and so is
    /// anything decoded without a language label.
    func testMatchingScriptAndFullPhrasesAreNotContradictions() {
        XCTAssertFalse(Transcriber.isScriptContradiction("Okay.", language: "en"))
        XCTAssertFalse(Transcriber.isScriptContradiction("Дякую.", language: "uk"),
                       "a real Ukrainian thanks in a Ukrainian decode must survive")
        XCTAssertFalse(Transcriber.isScriptContradiction("Дякую вам, до зустрічі завтра вранці", language: "en"),
                       "full phrases are the genuine-switch shape and are judged elsewhere")
        XCTAssertFalse(Transcriber.isScriptContradiction("Дякую.", language: nil))
    }

    // MARK: - Bootstrap stock fillers

    /// Line one of the 2026-07-29 call: nobody had spoken, and the meeting-join
    /// chime came through as "Others: Дякую!". Before a source has language
    /// momentum, Whisper's stock lone-word silence inventions must not commit.
    func testStockFillersAreDroppedBeforeMomentumExists() {
        for text in ["Дякую!", "you", "Thank you.", "Спасибо.", "Bye-bye.", "Music", "Музика"] {
            XCTAssertTrue(
                Transcriber.isBootstrapHallucination(text, hasMomentum: false),
                "\"\(text)\" is a stock silence filler and must not open a transcript")
        }
    }

    /// A real opener is not a stock filler — the gate must not eat the first
    /// word of a genuine meeting.
    func testRealOpenersSurviveTheBootstrapGate() {
        for text in ["Hello.", "Hi.", "Okay.", "Привіт!", "Доброго дня."] {
            XCTAssertFalse(
                Transcriber.isBootstrapHallucination(text, hasMomentum: false),
                "\"\(text)\" is a real opener and must survive")
        }
    }

    /// Once momentum exists the words become sayable again: the "Thank you.
    /// Bye." that ends a real meeting must never be dropped.
    func testStockWordsAreSayableOnceMomentumExists() {
        XCTAssertFalse(Transcriber.isBootstrapHallucination("Thank you.", hasMomentum: true))
        XCTAssertFalse(Transcriber.isBootstrapHallucination("Дякую!", hasMomentum: true))
    }

    // MARK: - Placement: order and turns

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func timing(_ start: Double, _ end: Double) -> UtteranceTiming {
        UtteranceTiming(start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
    }

    /// The ordering bug: "Yeah, it's exactly like accounting" appeared three
    /// turns before the line it answered, because the two streams decode
    /// independently and lines were appended as results arrived. A late-landing
    /// earlier utterance must sort back into place.
    func testLinesSortByWhenTheyWereSpokenNotWhenTheyDecoded() {
        var transcript: [TranscriptLine] = []
        // The short reply decodes first and lands first, exactly as it did in
        // the recording — where it appeared three turns above what it answered.
        _ = transcript.place(speaker: "Others", text: "Exactly like accounting.",
                             timing: timing(5, 6), mergeGap: 2, characterCap: 600)
        // The long utterance it replied to was spoken earlier but finished
        // decoding later. It belongs above, not below.
        _ = transcript.place(speaker: "You", text: "you have there like collapsible expandable",
                             timing: timing(0, 4), mergeGap: 2, characterCap: 600)
        // And a genuinely later utterance still lands at the end.
        _ = transcript.place(speaker: "You", text: "Okay, got it.",
                             timing: timing(7, 8), mergeGap: 2, characterCap: 600)

        XCTAssertEqual(transcript.map(\.text), [
            "you have there like collapsible expandable",
            "Exactly like accounting.",
            "Okay, got it.",
        ])
    }

    /// Ordering must not fight turn merging: an utterance that sorts in next to
    /// its own speaker's turn, close enough in time, still joins it.
    func testALateLandingUtteranceStillJoinsItsOwnTurn() {
        var transcript: [TranscriptLine] = []
        _ = transcript.place(speaker: "You", text: "you have there like collapsible expandable",
                             timing: timing(0, 4), mergeGap: 2, characterCap: 600)
        _ = transcript.place(speaker: "Others", text: "Exactly like accounting.",
                             timing: timing(5, 6), mergeGap: 2, characterCap: 600)
        _ = transcript.place(speaker: "You", text: "do we expect more items under tax?",
                             timing: timing(4.2, 4.8), mergeGap: 2, characterCap: 600)

        XCTAssertEqual(transcript.map(\.text), [
            "you have there like collapsible expandable do we expect more items under tax?",
            "Exactly like accounting.",
        ])
    }

    /// Turn fragmentation: Seal emitted up to nine consecutive `Others:` lines
    /// where Granola emitted one. Utterances from one speaker separated by an
    /// ordinary pause are one turn.
    func testConsecutiveUtterancesMergeIntoOneTurn() {
        var transcript: [TranscriptLine] = []
        let first = transcript.place(speaker: "Others", text: "Good. What else?",
                                     timing: timing(0, 2), mergeGap: 2, characterCap: 600)
        let second = transcript.place(speaker: "Others", text: "I need another filter for bills.",
                                      timing: timing(3, 5), mergeGap: 2, characterCap: 600)

        XCTAssertEqual(transcript.count, 1, "one speaker, one continuous turn, one line")
        XCTAssertEqual(first, second, "the second utterance joined the same line")
        XCTAssertEqual(transcript[0].text, "Good. What else? I need another filter for bills.")
        XCTAssertEqual(transcript[0].end, t0.addingTimeInterval(5), "the turn now ends later")
    }

    func testTurnsBreakOnSpeakerChangeLongPauseAndLength() {
        var transcript: [TranscriptLine] = []
        _ = transcript.place(speaker: "Others", text: "Good. What else?",
                             timing: timing(0, 2), mergeGap: 2, characterCap: 600)
        _ = transcript.place(speaker: "You", text: "Okay.",
                             timing: timing(2.2, 2.6), mergeGap: 2, characterCap: 600)
        XCTAssertEqual(transcript.count, 2, "a different speaker always starts a turn")

        _ = transcript.place(speaker: "You", text: "Sure, we'll do this.",
                             timing: timing(9, 10), mergeGap: 2, characterCap: 600)
        XCTAssertEqual(transcript.count, 3, "a long pause starts a new turn")

        _ = transcript.place(speaker: "You", text: "And another thing.",
                             timing: timing(10.5, 11), mergeGap: 2, characterCap: 10)
        XCTAssertEqual(transcript.count, 4, "a turn at the character cap stops absorbing")
    }

    /// Merging must not make the echo guard destructive: pulling the mic's
    /// ghost of the call audio back out takes that utterance only, not the
    /// whole turn it was merged into.
    func testRemovingAnEchoedUtteranceKeepsTheRestOfItsTurn() {
        var transcript: [TranscriptLine] = []
        _ = transcript.place(speaker: "You", text: "Only main transactions, not all included.",
                             timing: timing(0, 3), mergeGap: 2, characterCap: 600)
        _ = transcript.place(speaker: "You", text: "the payment information on the row",
                             timing: timing(4, 6), mergeGap: 2, characterCap: 600)
        XCTAssertEqual(transcript.count, 1)

        transcript[0].fragments.removeAll { $0 == "the payment information on the row" }
        XCTAssertEqual(transcript[0].text, "Only main transactions, not all included.",
                       "the ghost left; the real utterance stayed")
    }
}
