import XCTest
@testable import Seal

/// The pure half of speaker identification: cluster naming, matching diarizer
/// turns to transcript lines, and the legacy wall-clock alignment. The model
/// inference itself is exercised against real recordings, not here.
final class SpeakerLabelerTests: XCTestCase {

    // MARK: - Cluster naming

    func testVoicesAreNamedByTalkTimeAndStable() {
        let turns = SpeakerLabeler.normalized([
            (id: "spk_9", start: 0, end: 5),      // 5 s
            (id: "spk_2", start: 5, end: 25),     // 20 s — the most talk
            (id: "spk_9", start: 25, end: 27),    // spk_9 totals 7 s
        ])
        XCTAssertEqual(turns.map(\.speaker), ["S2", "S1", "S2"],
                       "the biggest voice is S1, whatever the model called it")
        XCTAssertEqual(turns.map(\.start), [0, 5, 25], "chronological order")
    }

    func testZeroLengthTurnsAreDropped() {
        let turns = SpeakerLabeler.normalized([
            (id: "a", start: 3, end: 3),
            (id: "b", start: 0, end: 4),
        ])
        XCTAssertEqual(turns.map(\.speaker), ["S1"])
    }

    // MARK: - Matching a line to a voice

    private let turns = [
        SpeakerTurn(speaker: "S1", start: 0, end: 30),
        SpeakerTurn(speaker: "S2", start: 30, end: 40),
        SpeakerTurn(speaker: "S1", start: 40, end: 60),
    ]

    func testMajorityOverlapWins() {
        // 28–33 straddles the S1→S2 handoff: 2 s of S1, 3 s of S2.
        XCTAssertEqual(SpeakerLabeler.voice(from: 28, to: 33, in: turns), "S2")
        XCTAssertEqual(SpeakerLabeler.voice(from: 5, to: 12, in: turns), "S1")
    }

    func testAGapFallsToTheNearestTurnOnlyWithinReach() {
        let sparse = [SpeakerTurn(speaker: "S1", start: 0, end: 10),
                      SpeakerTurn(speaker: "S2", start: 20, end: 30)]
        // 11–13 overlaps nothing; S1 ends 1 s before it, S2 starts 7 s after.
        XCTAssertEqual(SpeakerLabeler.voice(from: 11, to: 13, in: sparse), "S1")
        // 14.5–16: nearest edge is 4 s away — beyond reach, better unlabeled.
        XCTAssertNil(SpeakerLabeler.voice(from: 14.5, to: 16, in: sparse))
    }

    func testAnEmptySpanIsNeverLabeled() {
        XCTAssertNil(SpeakerLabeler.voice(from: 10, to: 10, in: turns))
    }

    // MARK: - Labeling a transcript

    func testOnlyFarSideLinesWithOffsetsAreLabeled() {
        var lines = [
            StoredLine(speaker: "You", text: "mine", start: 1, end: 2),
            StoredLine(speaker: "Others", text: "theirs", start: 5, end: 12),
            StoredLine(speaker: "Others", text: "old line, no offsets"),
            StoredLine(speaker: "Others", text: "handoff", start: 28, end: 33),
        ]
        let labeled = SpeakerLabeler.label(&lines, with: turns)
        XCTAssertEqual(labeled, 2)
        XCTAssertNil(lines[0].voice, "the mic is never relabeled")
        XCTAssertEqual(lines[1].voice, "S1")
        XCTAssertNil(lines[2].voice)
        XCTAssertEqual(lines[3].voice, "S2")
    }

    func testVoicesInLinesAreNumericallyOrdered() {
        var lines: [StoredLine] = []
        for v in ["S10", "S2", "S1", "S2"] {
            var line = StoredLine(speaker: "Others", text: "x")
            line.voice = v
            lines.append(line)
        }
        XCTAssertEqual(SpeakerLabeler.voices(in: lines), ["S1", "S2", "S10"])
    }

    // MARK: - Legacy meetings (wall clock, no offsets)

    /// Old meetings' commit dates lead the audio clock by an unknown constant
    /// (model load ran before capture). The estimator must recover it and
    /// place lines correctly through it.
    func testLegacyAlignmentRecoversAConstantShift() {
        let meetingStart = Date(timeIntervalSince1970: 1_800_000_000)
        let shift = 4.2   // wall clock runs this far ahead of the audio clock
        var lines = [10.0, 32.0, 45.0].map { audioStart in
            StoredLine(speaker: "Others", text: "line",
                       at: meetingStart.addingTimeInterval(audioStart + shift))
        }
        let labeled = SpeakerLabeler.labelLegacy(&lines, with: turns, meetingStart: meetingStart)
        XCTAssertEqual(labeled, 3)
        XCTAssertEqual(lines.map(\.voice), ["S1", "S2", "S1"])
    }

    func testLegacyAlignmentDeclinesOnTooFewLines() {
        let meetingStart = Date(timeIntervalSince1970: 1_800_000_000)
        var lines = [StoredLine(speaker: "Others", text: "only one",
                                at: meetingStart.addingTimeInterval(12))]
        XCTAssertEqual(SpeakerLabeler.labelLegacy(&lines, with: turns, meetingStart: meetingStart), 0)
        XCTAssertNil(lines[0].voice, "one dated line is not enough evidence to align a clock")
    }
}
