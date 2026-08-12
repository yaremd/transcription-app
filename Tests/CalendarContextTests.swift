import XCTest
@testable import Seal

/// Calendar context (YAR-36): which event a recording belongs to, and how its
/// title and attendees flow into the meeting. Pure logic only — EventKit
/// itself is exercised by the field pass, not the test host.
final class CalendarContextTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, start: TimeInterval, end: TimeInterval,
                       allDay: Bool = false, attendees: [String] = []) -> CalendarContext.Candidate {
        CalendarContext.Candidate(title: title,
                                  start: now.addingTimeInterval(start),
                                  end: now.addingTimeInterval(end),
                                  isAllDay: allDay, attendees: attendees)
    }

    func testCoveringEventWinsAndShortestCoveringWinsOutright() {
        // The 30-minute standup inside a week-long offsite IS the meeting.
        let picked = CalendarContext.pick(from: [
            event("Offsite week", start: -3 * 3600, end: 5 * 3600),
            event("Daily standup", start: -600, end: 1200, attendees: ["Kumar", "Lana"]),
        ], at: now)
        XCTAssertEqual(picked?.title, "Daily standup")
        XCTAssertEqual(picked?.attendees, ["Kumar", "Lana"])
    }

    func testUpcomingWithinTenMinutesCountsWhenNothingCovers() {
        let picked = CalendarContext.pick(from: [
            event("Vendor evaluation", start: 300, end: 3900),
        ], at: now)
        XCTAssertEqual(picked?.title, "Vendor evaluation")
    }

    func testEndedAndDistantEventsNeverName() {
        // Naming a recording after a meeting that ended an hour ago is worse
        // than no name at all.
        XCTAssertNil(CalendarContext.pick(from: [
            event("Morning sync", start: -7200, end: -3600),
            event("Tomorrow's kickoff", start: 20 * 60, end: 21 * 60),
        ], at: now))
    }

    func testAllDayAndUntitledEventsAreContextNotMeetings() {
        XCTAssertNil(CalendarContext.pick(from: [
            event("Public holiday", start: -12 * 3600, end: 12 * 3600, allDay: true),
            event("   ", start: -600, end: 600),
        ], at: now))
    }

    func testAttendeesAreDedupedTrimmedAndCapped() {
        let names = ["Kumar ", "kumar", "Lana", ""] + (1...20).map { "Guest \($0)" }
        let picked = CalendarContext.pick(from: [
            event("Big review", start: -60, end: 3600, attendees: names),
        ], at: now)
        XCTAssertEqual(picked?.attendees.count, 12)
        XCTAssertEqual(picked?.attendees.prefix(2), ["Kumar", "Lana"])
    }

    // MARK: - Flow into the meeting

    func testStartingTitlePrefersUserThenCalendarThenPlaceholder() {
        XCTAssertEqual(Meeting.startingTitle(existing: "My own name", calendar: "Standup"), "My own name")
        XCTAssertEqual(Meeting.startingTitle(existing: Meeting.defaultTitle, calendar: "Standup"), "Standup")
        XCTAssertEqual(Meeting.startingTitle(existing: nil, calendar: "  Standup  "), "Standup")
        XCTAssertEqual(Meeting.startingTitle(existing: nil, calendar: nil), Meeting.defaultTitle)
        XCTAssertEqual(Meeting.startingTitle(existing: "", calendar: ""), Meeting.defaultTitle)
    }

    func testAITranscriptCarriesTheInviteList() {
        var m = Meeting(title: "T", date: Date(), duration: 60, language: "en",
                        lines: [StoredLine(speaker: "You", text: "Hello.")], notes: "")
        XCTAssertFalse(m.aiTranscript.contains("INVITED"))
        m.calendarAttendees = ["Kumar", "Lana"]
        XCTAssertTrue(m.aiTranscript.hasPrefix("INVITED (from calendar): Kumar, Lana\n\n"))
        m.speakerNames = ["S1": "Kumar"]
        XCTAssertTrue(m.aiTranscript.contains("PARTICIPANTS: S1 = Kumar"))
        XCTAssertTrue(m.aiTranscript.contains("INVITED (from calendar): Kumar, Lana"))
    }
}
