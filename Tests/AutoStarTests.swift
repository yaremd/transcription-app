import XCTest
@testable import Seal

/// What Seal stars on its own as the transcript lands: your name from the
/// call's side, a decision, a task with a deadline — and not ordinary talk.
final class AutoStarTests: XCTestCase {

    private func reason(_ text: String, fromOthers: Bool = true, name: String = "") -> AutoStar.Reason? {
        AutoStar.detect(text, fromOthers: fromOthers, userName: name)?.reason
    }

    func testYourNameFromTheCallIsStarred() {
        XCTAssertEqual(reason("Dmytro, can you walk us through the numbers?", name: "Dmytro"), .name)
        XCTAssertEqual(reason("I think Dmytro's point is right.", name: "Dmytro Yaremchuk"), .name)
    }

    func testYourNameIsHeardInTheOtherAlphabetAndAnyCase() {
        XCTAssertEqual(reason("Дмитре, що скажеш?", name: "Dmytro"), .name)
        XCTAssertEqual(reason("Це питання до Дмитра.", name: "Dmytro"), .name)
        XCTAssertEqual(reason("Dmytro, are you there?", name: "Дмитро"), .name)
    }

    func testYouSayingYourOwnNameIsAnIntroduction() {
        XCTAssertNil(reason("Hi, I'm Dmytro, I run the product.", fromOthers: false, name: "Dmytro"))
    }

    func testANameInsideAnotherWordIsNotYourName() {
        XCTAssertNil(reason("The market moved a lot.", name: "Mark"))
    }

    func testDecisionsInEitherLanguage() {
        XCTAssertEqual(reason("Okay, so we decided to ship on the 20th."), .decision)
        XCTAssertEqual(reason("Let's go with the second option."), .decision)
        XCTAssertEqual(reason("Добре, домовились, запускаємо в понеділок."), .decision)
        XCTAssertEqual(reason("Ми вирішили не чекати."), .decision)
    }

    func testATaskNeedsADeadlineOrADirectAsk() {
        XCTAssertEqual(reason("Can you send me the deck by Friday?"), .task)
        XCTAssertEqual(reason("I'll have the draft ready by end of day."), .task)
        XCTAssertEqual(reason("Можеш надіслати звіт до п’ятниці?"), .task)
        XCTAssertEqual(reason("That's an action item for the team."), .task)
        XCTAssertEqual(reason("Could you check it tomorrow?"), .task)
    }

    func testOrdinaryTalkIsNotStarred() {
        XCTAssertNil(reason("Can you hear me okay?"))
        XCTAssertNil(reason("I'll see you tomorrow."))
        XCTAssertNil(reason("We disagreed about the colours."))
        XCTAssertNil(reason("Привіт, як справи?"))
    }

    func testTheNoteQuotesTheSentenceThatSetItOff() {
        let hit = AutoStar.detect("Thanks all. We decided to ship on Friday. Any questions?",
                                  fromOthers: true, userName: "")
        XCTAssertEqual(hit?.quote, "We decided to ship on Friday.")
        XCTAssertEqual(hit.map(AutoStar.noteText), "☆ Decision: “We decided to ship on Friday.”")
        XCTAssertEqual(hit.map { NoteMark.parse(AutoStar.noteText(for: $0)) }.map { mark -> Bool in
            if case .flagged = mark { return true }
            return false
        }, true)
    }

    func testNamesCrossBetweenAlphabets() {
        XCTAssertEqual(AutoStar.cyrillic(fromLatin: "dmytro"), "дмитро")
        XCTAssertEqual(AutoStar.cyrillic(fromLatin: "oleksandr"), "олександр")
        XCTAssertEqual(AutoStar.latin(fromCyrillic: "дмитро"), "dmytro")
    }
}
