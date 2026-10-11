import XCTest
@testable import Seal

/// The notes are the user's own, not a log about "the user".
final class NotesVoiceTests: XCTestCase {

    private func meeting(names: [String: String]? = nil) -> Meeting {
        Meeting(title: "Pilot review", date: Date(), duration: 60, language: "en",
                lines: [StoredLine(speaker: "You", text: "Let's keep the rollout to support."),
                        StoredLine(speaker: "Others", text: "Agreed.")],
                notes: "", speakerNames: names)
    }

    func testThePromptNeverCallsAnyoneTheUser() {
        let prompt = NotesGenerator().buildPrompt(transcript: "You: hi", userNotes: "",
                                                  template: .general, language: "English")
        XCTAssertFalse(prompt.system.contains("the app's user"))
        XCTAssertTrue(prompt.system.contains("never as \"the user\""))
        XCTAssertTrue(prompt.system.contains("call people by the names the PARTICIPANTS header gives"))
    }

    func testTheUsersNameFromSettingsNamesYou() {
        let m = meeting()
        XCTAssertEqual(m.aiParticipants(userName: "Dmytro"), "PARTICIPANTS: You = Dmytro")
        XCTAssertTrue(m.aiTranscript(userName: "Dmytro").hasPrefix("PARTICIPANTS: You = Dmytro\n\nYou: "))
    }

    func testAConfirmedNameForYouOutranksSettings() {
        let m = meeting(names: ["You": "Dima", "Others": "Daniel"])
        XCTAssertEqual(m.aiParticipants(userName: "Dmytro"), "PARTICIPANTS: Others = Daniel; You = Dima")
    }

    func testNoNamesMeansNoHeader() {
        let m = meeting()
        XCTAssertNil(m.aiParticipants(userName: "   "))
        XCTAssertNil(m.aiParticipants(userName: nil))
        XCTAssertFalse(m.aiTranscript.contains("PARTICIPANTS"))
    }
}
