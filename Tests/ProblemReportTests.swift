import XCTest
@testable import Seal

/// The report exists so a stranger can tell you what a `.diag.log` already
/// knows. Every line below is copied verbatim from the logs of the two
/// 2026-08-05 meetings, because those are the shapes it has to survive.
final class ProblemReportTests: XCTestCase {

    /// The 21-minute planning call, in miniature: a prompted decode that keeps
    /// emptying, a committed utterance that produces nothing, filtered lines,
    /// votes, and a detection outside the allowed set.
    private let realLog = """
        0.00 session start — speed=fast language=auto keepAudio=true
        2.75 [Others] commit #0 buffered=2.6s voiced=0.5s -> 1.1s to decode
        2.81 [Others]   en: empty with a prompt, retried without -> "Hang in a minute."
        3.15 [Others] detect: ko p=outside-allowed-set inAllowed=false
        4.88 [Others] commit #0 queued=0.0s decode=2.1s depth=1 -> "Хайгинь мен това."
        5.52     seg-drop empty-segment noSpeech=0.00 logprob=0.00 cr=0.00 ""
        7.65 [Others] commit #1 buffered=4.2s voiced=2.7s -> 3.6s to decode
        8.98 [Others] commit #1 queued=0.4s decode=1.3s depth=1 -> EMPTY (decoded to nothing)
       25.32 [Others] VOTE uk (tally ["uk": 1])
       41.18 [Others] VOTE en (tally ["uk": 1, "en": 1])
      120.56 [You] commit #10 buffered=2.0s voiced=0.3s -> 0.9s to decode
      122.55 [You] commit #10 queued=0.0s decode=4.0s depth=1 -> "Thank you."
      122.60 [You] DROP stock filler (every candidate answered with one, 0.9s of audio): "Thank you."
      276.50 [You] commit #5 buffered=1.1s voiced=0.1s -> SKIPPED (too little speech)
      294.07 [Others] force-cut #35 at 17.8s voiced=13.1s -> 16.4s to decode
      295.15 [Others] commit #35 queued=0.0s decode=1.1s depth=1 -> "So I raised two PRs."
      300.00 PROMPT ABANDONED after 3 consecutive empty prompted decodes
      301.00 name: "Demitra" -> "Dmytro"
      """

    func testTheCountsThatDiagnoseAMeetingAreRead() {
        let d = ProblemReport.diagnostics(fromLog: realLog)
        XCTAssertEqual(d.sessionLine, "speed=fast language=auto keepAudio=true")
        XCTAssertEqual(d.utterancesDecoded, 4, "four utterances came back")
        XCTAssertEqual(d.utterancesEmpty, 1, "one of them produced no text")
        XCTAssertEqual(d.secondsEmpty, 3.6, accuracy: 0.01, "and it was 3.6s of speech")
        XCTAssertEqual(d.secondsDecoded, 1.1 + 3.6 + 0.9 + 16.4, accuracy: 0.01)
        XCTAssertEqual(d.utterancesSkipped, 1)
        XCTAssertEqual(d.segmentDrops["empty-segment"], 1)
        XCTAssertEqual(d.guardDrops["stock filler"], 1, "the reason, never the words")
        XCTAssertEqual(d.votes, ["uk": 1, "en": 1])
        XCTAssertEqual(d.detectionsOutsideAllowedSet, 1)
        XCTAssertEqual(d.promptRetries, 1)
        XCTAssertTrue(d.promptAbandoned)
        XCTAssertEqual(d.namesCorrected, 1)
        XCTAssertEqual(d.decodeSecondsMax, 4.0, accuracy: 0.01)
        XCTAssertEqual(d.queueSecondsMax, 0.4, accuracy: 0.01)
        XCTAssertEqual(d.decodeErrors, 0)
    }

    /// An utterance cut at the length cap is handed over as "force-cut #35" and
    /// comes back as "commit #35". Pairing them by marker instead of number
    /// priced every one of them at zero seconds — and those are the longest
    /// utterances there are, so the lost-speech figure was quietly wrong.
    func testAForceCutUtteranceIsPricedLikeAnyOther() {
        let d = ProblemReport.diagnostics(fromLog: """
            1.00 [Others] force-cut #35 at 17.8s voiced=13.1s -> 16.4s to decode
            2.00 [Others] commit #35 queued=0.0s decode=1.1s depth=1 -> EMPTY (decoded to nothing)
            """)
        XCTAssertEqual(d.utterancesEmpty, 1)
        XCTAssertEqual(d.secondsEmpty, 16.4, accuracy: 0.01, "16.4s of speech was lost, not 0")
    }

    /// The whole point of the summary: it must carry no speech. The log above
    /// quotes six things people said (and one Cyrillic hallucination); none of
    /// them may reach the report.
    func testTheReportContainsNoTranscriptText() {
        let report = ProblemReport.text(
            description: "the other side cut out",
            meeting: Self.meeting, diagnostics: ProblemReport.diagnostics(fromLog: realLog),
            environment: Self.environment, attachingLog: false)
        for spoken in ["Hang in a minute", "Хайгинь", "Thank you", "So I raised two PRs", "Demitra", "Dmytro"] {
            XCTAssertFalse(report.contains(spoken),
                           "\"\(spoken)\" was said in the meeting and must not be in the report")
        }
        XCTAssertTrue(report.contains("the other side cut out"), "the user's own words are the report")
    }

    /// And it must say the thing that matters, in a form a person can act on.
    func testTheReportLeadsWithTheLostSpeech() {
        let report = ProblemReport.text(
            description: "", meeting: Self.meeting,
            diagnostics: ProblemReport.diagnostics(fromLog: realLog),
            environment: Self.environment, attachingLog: false)
        XCTAssertTrue(report.contains("produced NO text"), "the failure has to be named")
        XCTAssertTrue(report.contains("1 empty-segment"))
        XCTAssertTrue(report.contains("prompt abandoned"))
        XCTAssertTrue(report.contains("No transcript text is included"))
    }

    /// Attaching the log is the moment speech could leave the Mac, so the
    /// report says so in plain words.
    func testAttachingTheLogIsStatedOutright() {
        let report = ProblemReport.text(
            description: "", meeting: Self.meeting, diagnostics: nil,
            environment: Self.environment, attachingLog: true)
        XCTAssertTrue(report.contains("quotes what was said"))
    }

    /// A meeting recorded before diagnostics existed still produces a report.
    func testAMeetingWithoutALogStillReports() {
        let report = ProblemReport.text(
            description: "no audio at all", meeting: Self.meeting, diagnostics: nil,
            environment: Self.environment, attachingLog: false)
        XCTAssertTrue(report.contains("No diagnostics log"))
        XCTAssertTrue(report.contains("no audio at all"))
    }

    /// Logs from older builds carry lines this parser has never seen; they must
    /// be ignored rather than miscounted.
    func testUnknownAndTruncatedLogsAreHandled() {
        let d = ProblemReport.diagnostics(fromLog: """
            0.00 something from a future build nobody wrote a parser for
            1.00 [Others]   en: DECODE THREW: the model call did not finish in time
                 --- diagnostics truncated at 8388608 bytes ---
            """)
        XCTAssertTrue(d.truncated)
        XCTAssertEqual(d.decodeErrors, 1)
        XCTAssertEqual(d.utterancesDecoded, 0)
    }

    // MARK: - Fixtures

    private static let meeting = Meeting(
        title: "Sprint standup", date: Date(timeIntervalSince1970: 1_780_000_000),
        duration: 1_290, language: "auto",
        lines: [StoredLine(speaker: "Others", text: "…")], notes: "")

    private static let environment = ProblemReport.Environment(
        appVersion: "0.13", build: "13", system: "macOS 15.5.0",
        hardware: "Mac15,7 (Apple silicon)", memoryGB: 18)
}
