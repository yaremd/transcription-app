import XCTest
@testable import Seal

/// Ink for the user's lines, muted ink for the model's — decided line by
/// line against the model's own output.
final class NotesProvenanceTests: XCTestCase {

    func testLinesTheModelWroteAreTheModels() {
        let generated = "## Summary\n- Agreed to ship Friday\n\n## Decisions\n- Blue"
        let lines = NotesProvenance.classify(notes: generated, generated: generated, fallback: .human)
        XCTAssertEqual(lines.map(\.source), [.ai, .ai, .ai, .ai, .ai])
    }

    func testAnEditedLineBecomesTheUsers() {
        let generated = "## Summary\n- Agreed to ship Friday"
        let notes = "## Summary\n- Agreed to ship Thursday\n- My own addition"
        let lines = NotesProvenance.classify(notes: notes, generated: generated, fallback: .ai)
        XCTAssertEqual(lines.map(\.source), [.ai, .human, .human])
        XCTAssertEqual(lines[2].text, "- My own addition")
    }

    func testWhitespaceAroundALineDoesNotMakeItTheUsers() {
        let lines = NotesProvenance.classify(notes: "  - Point  ", generated: "- Point", fallback: .ai)
        XCTAssertEqual(lines.map(\.source), [.ai])
    }

    func testBlankLinesNeverCountAsEdits() {
        let lines = NotesProvenance.classify(notes: "- A\n\n- B", generated: "- A\n- B", fallback: .ai)
        XCTAssertEqual(lines.map(\.source), [.ai, .ai, .ai])
    }

    func testNotesWithoutARecordUseTheFallback() {
        XCTAssertEqual(NotesProvenance.classify(notes: "- A", generated: nil, fallback: .human).map(\.source), [.human])
        XCTAssertEqual(NotesProvenance.classify(notes: "- A", generated: nil, fallback: .ai).map(\.source), [.ai])
    }
}
