import XCTest
@testable import Seal

/// Runtime proof for Ask on the on-device model: a question about a short
/// transcript streams back in more than one piece, answers from the text, and
/// a second question — asked after one more line was "said" — goes through
/// the same conversation. Needs the notes model on disk (it downloads on
/// first use, like the notes engine's own smoke test).
final class AskStreamSmokeTests: XCTestCase {
    func testAQuestionStreamsAnAnswerFromTheTranscript() async throws {
        try XCTSkipUnless(MLXEngine.isSupported, "MLX requires Apple silicon")

        let meetingID = UUID()
        func line(_ speaker: String, _ text: String, at: TimeInterval) -> AskTranscriptFeed.Line {
            AskTranscriptFeed.Line(id: UUID(), label: "\(AskTranscriptFeed.stamp(at)) \(speaker)", text: text)
        }
        var lines = [
            line("Others", "Legal asked for a one-page summary of what stays on the device. Can you send that by Friday?", at: 10),
            line("You", "Yes, I'll have it to you by Thursday.", at: 14),
        ]
        let instructions = """
        You answer questions about a meeting using ONLY its transcript, which arrives in pieces. \
        Lines read "[time] Speaker: words". Lines labeled "You" were spoken by the person asking you — address them as "you". \
        Be concise. Write in English.
        """

        var chunks: [String] = []
        let first = try await MLXEngine.shared.ask(meetingID: meetingID, instructions: instructions,
                                                   lines: lines, question: "By which day will the summary be sent?")
        for try await chunk in first { chunks.append(chunk) }
        let answer = chunks.joined()
        print("=== ASK SMOKE 1 (\(chunks.count) chunks): '\(answer)' ===")
        XCTAssertGreaterThan(chunks.count, 1, "the answer should stream in pieces, not land whole")
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("Thursday"), "answer should come from the transcript")

        // One more line said since; the conversation carries on with just it.
        lines.append(line("Others", "Thursday works. Also, please copy Maria on it.", at: 20))
        var second = ""
        let followUp = try await MLXEngine.shared.ask(meetingID: meetingID, instructions: instructions,
                                                      lines: lines, question: "Who should be copied on the summary?")
        for try await chunk in followUp { second += chunk }
        print("=== ASK SMOKE 2: '\(second)' ===")
        XCTAssertTrue(second.localizedCaseInsensitiveContains("Maria"), "a later question should see the newer line")

        await MLXEngine.shared.dropConversation(for: meetingID)
    }
}
