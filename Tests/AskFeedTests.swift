import XCTest
@testable import Seal

/// What a question carries to the model: everything the first time, only
/// what was said since after that — and a fresh start the moment the lines
/// already read stop matching the meeting.
final class AskFeedTests: XCTestCase {

    private func line(_ speaker: String, _ text: String, at: TimeInterval = 0) -> AskTranscriptFeed.Line {
        line(UUID(), speaker, text, at: at)
    }

    private func line(_ id: UUID, _ speaker: String, _ text: String, at: TimeInterval = 0) -> AskTranscriptFeed.Line {
        AskTranscriptFeed.Line(id: id, label: "\(AskTranscriptFeed.stamp(at)) \(speaker)", text: text)
    }

    func testFirstQuestionCarriesTheWholeTranscript() {
        var feed = AskTranscriptFeed()
        let lines = [line("You", "Hello", at: 0), line("Others", "Hi there", at: 3)]
        XCTAssertEqual(feed.update(with: lines),
                       .restart("[00:00] You: Hello\n[00:03] Others: Hi there"))
        XCTAssertFalse(feed.isEmpty)
    }

    func testLaterQuestionCarriesOnlyWhatWasSaidSince() {
        var feed = AskTranscriptFeed()
        let a = line("You", "Hello", at: 0)
        _ = feed.update(with: [a])
        let b = line("Others", "Hi there", at: 3)
        XCTAssertEqual(feed.update(with: [a, b]), .append("[00:03] Others: Hi there"))
        XCTAssertEqual(feed.update(with: [a, b]), .nothing)
    }

    func testALineStillBeingSpokenFeedsOnlyItsGrowth() {
        var feed = AskTranscriptFeed()
        let id = UUID()
        _ = feed.update(with: [line(id, "Others", "We should ship")])
        let grown = line(id, "Others", "We should ship on Friday, not Monday")
        XCTAssertEqual(feed.update(with: [grown]),
                       .append("[00:00] Others (continued): on Friday, not Monday"))
    }

    /// A long utterance that finishes decoding after a shorter, later one is
    /// inserted where it was spoken — in the middle. That is new text, not a
    /// changed transcript, so the conversation carries on.
    func testALineInsertedEarlierIsAppendedNotRestarted() {
        var feed = AskTranscriptFeed()
        let a = line("You", "First", at: 0)
        let c = line("You", "Third", at: 10)
        _ = feed.update(with: [a, c])
        let b = line("Others", "Second, which took a while to decode", at: 5)
        XCTAssertEqual(feed.update(with: [a, b, c]),
                       .append("[00:05] Others: Second, which took a while to decode"))
    }

    func testAnEditedLineStartsOver() {
        var feed = AskTranscriptFeed()
        let id = UUID()
        _ = feed.update(with: [line(id, "You", "We agreed on blue")])
        let edited = line(id, "You", "We agreed on green")
        XCTAssertEqual(feed.update(with: [edited]), .restart("[00:00] You: We agreed on green"))
    }

    func testAReplacedTranscriptStartsOver() {
        var feed = AskTranscriptFeed()
        _ = feed.update(with: [line("You", "Old pass")])
        let fresh = [line("You", "Accurate pass"), line("Others", "Indeed")]
        XCTAssertEqual(feed.update(with: fresh),
                       .restart("[00:00] You: Accurate pass\n[00:00] Others: Indeed"))
        XCTAssertEqual(feed.update(with: fresh), .nothing)
    }

    func testStampsReadAsClockTimes() {
        XCTAssertEqual(AskTranscriptFeed.stamp(0), "[00:00]")
        XCTAssertEqual(AskTranscriptFeed.stamp(65), "[01:05]")
        XCTAssertEqual(AskTranscriptFeed.stamp(3725), "[1:02:05]")
        XCTAssertEqual(AskTranscriptFeed.stamp(-4), "[00:00]")
    }
}
