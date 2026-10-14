import XCTest
@testable import Seal

/// What a "/word" in the Ask bar finds: the command word first, then a word
/// of the title, then anywhere in it, in the page's own order on a tie.
final class AskBarMatchTests: XCTestCase {

    private func action(_ id: String, _ title: String) -> AskBarAction {
        AskBarAction(id: id, title: title, symbol: "circle", group: .notes)
    }

    private lazy var actions = [
        action("rewrite", "Rewrite the notes"),
        action("as-sales", "Rewrite as Sales call"),
        action("shorter", "Make the notes shorter"),
        action("actions", "Find action items"),
        action("follow-up", "Draft a follow-up email"),
        action("pdf", "Export as PDF…"),
    ]

    private func ids(_ query: String) -> [String] {
        AskBarMatch.filter(actions, query: query).map(\.id)
    }

    func testTheCommandWordWinsOverATitleWord() {
        // "act" starts the word "actions" and the title word "action";
        // the command word ranks first, and nothing else matches.
        XCTAssertEqual(ids("act"), ["actions"])
        // "short" is the start of a command word.
        XCTAssertEqual(ids("short").first, "shorter")
    }

    func testAWordOfTheTitleFindsAnAction() {
        XCTAssertEqual(ids("email"), ["follow-up"])
        XCTAssertEqual(ids("sales"), ["as-sales"])
    }

    func testHyphensAndSpacesAreTheSameToWhoeverTypes() {
        XCTAssertEqual(ids("follow up"), ["follow-up"])
        XCTAssertEqual(ids("as s"), ["as-sales"])
    }

    func testCaseAndSurroundingSpaceDoNotMatter() {
        XCTAssertEqual(ids("  PDF "), ["pdf"])
    }

    func testABareSlashListsEverythingInOrder() {
        XCTAssertEqual(ids(""), actions.map(\.id))
    }

    func testNothingMatchesNonsense() {
        XCTAssertEqual(ids("zebra"), [])
    }

    func testTiesKeepThePagesOrder() {
        // Both titles contain "notes" as a word: the page listed "rewrite" first.
        XCTAssertEqual(ids("notes"), ["rewrite", "shorter"])
    }
}
