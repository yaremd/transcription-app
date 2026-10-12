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

    /// A file beside the question is answered from, and told apart from the
    /// meeting: the transcript never names the budget, the attached plan does.
    func testAQuestionAboutAnAttachedFileIsAnsweredFromIt() async throws {
        try XCTSkipUnless(MLXEngine.isSupported, "MLX requires Apple silicon")

        let meetingID = UUID()
        let lines = [
            AskTranscriptFeed.Line(id: UUID(), label: "[00:10] Others", text: "Let's go through the rollout plan I sent."),
            AskTranscriptFeed.Line(id: UUID(), label: "[00:14] You", text: "Sure, I have it open."),
        ]
        let instructions = """
        You answer questions about a meeting using ONLY its transcript and the files the asker attaches. \
        Lines read "[time] Speaker: words". A block labeled ATTACHED is a file the asker put beside their question. \
        Be concise. Write in English.
        """
        let attached = AskDocument.promptBlock([
            AskDocument(name: "Q3 rollout plan.md",
                        text: "# Q3 rollout plan\n- Support team first\n- Budget: 1.2M, owner Maria\n- Sales after legal sign-off"),
        ])
        var answer = ""
        let stream = try await MLXEngine.shared.ask(meetingID: meetingID, instructions: instructions, lines: lines,
                                                    question: "What budget does the attached plan give, and who owns it?",
                                                    attachments: attached)
        for try await chunk in stream { answer += chunk }
        print("=== ASK ATTACHMENT SMOKE: '\(answer)' ===")
        XCTAssertTrue(answer.contains("1.2M") || answer.contains("1.2 M") || answer.contains("1,2"), "the budget comes from the file")
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("Maria"), "the owner comes from the file")

        await MLXEngine.shared.dropConversation(for: meetingID)
    }
}
