import XCTest
import AppKit
@testable import Seal

/// A screen capture is read into text on the Mac and takes its place in the
/// transcript at the moment it was taken.
final class ScreenContextTests: XCTestCase {

    // MARK: - Reading order

    private func line(_ text: String, x: CGFloat, y: CGFloat, h: CGFloat = 0.05) -> ScreenTextReader.ReadLine {
        ScreenTextReader.ReadLine(text: text, box: CGRect(x: x, y: y, width: 0.3, height: h))
    }

    func testLinesReadTopToBottomAndAcrossARow() {
        let title = line("Q3 rollout", x: 0.1, y: 0.9)
        let left = line("Support: 70% daily", x: 0.1, y: 0.5)
        let right = line("Sales: slower", x: 0.6, y: 0.51)   // same row, to the right
        let footer = line("Next: legal summary", x: 0.1, y: 0.1)
        let ordered = ScreenTextReader.readingOrder([footer, right, title, left]).map(\.text)
        XCTAssertEqual(ordered, ["Q3 rollout", "Support: 70% daily", "Sales: slower", "Next: legal summary"])
    }

    // MARK: - Where a capture lands

    private func meeting(frames: [ScreenFrame]?) -> Meeting {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return Meeting(title: "Pilot", date: start, duration: 60, language: "en",
                       lines: [StoredLine(speaker: "Others", text: "Here is the plan.", at: start.addingTimeInterval(10)),
                               StoredLine(speaker: "You", text: "Looks good.", at: start.addingTimeInterval(30))],
                       notes: "", frames: frames)
    }

    func testACaptureSitsBeforeTheFirstLineSpokenAfterIt() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let slide = ScreenFrame(at: start.addingTimeInterval(20), text: "Rollout\nSupport first", sourceApp: "Zoom", fileName: "a.jpg")
        let late = ScreenFrame(at: start.addingTimeInterval(90), text: "Thanks", fileName: "b.jpg")
        let lines = meeting(frames: [late, slide]).aiTranscript.components(separatedBy: "\n")
        XCTAssertEqual(lines, ["Others: Here is the plan.",
                               "On screen (Zoom): Rollout | Support first",
                               "You: Looks good.",
                               "On screen: Thanks"])
    }

    func testLinesWithoutTimestampsKeepTheirOrderAndCapturesFollow() {
        let frame = ScreenFrame(at: Date(), text: "Slide", fileName: "a.jpg")
        let m = Meeting(title: "Old", date: Date(), duration: 1, language: "en",
                        lines: [StoredLine(speaker: "You", text: "First"), StoredLine(speaker: "Others", text: "Second")],
                        notes: "", frames: [frame])
        XCTAssertEqual(m.aiTranscript.components(separatedBy: "\n"), ["You: First", "Others: Second", "On screen: Slide"])
    }

    func testAskSeesTheCaptureAsItsOwnLine() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let slide = ScreenFrame(at: start.addingTimeInterval(65), text: "Budget 1.2M", sourceApp: "Zoom", fileName: "a.jpg")
        let lines = meeting(frames: [slide]).askLines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.last?.id, slide.id)
        XCTAssertEqual(lines.last?.label, "[01:05] On screen (Zoom)")
        XCTAssertEqual(lines.last?.text, "Budget 1.2M")
    }

    func testCopyAndExportTextStaysSpeechOnly() {
        let frame = ScreenFrame(at: Date(), text: "Secret slide", fileName: "a.jpg")
        XCTAssertFalse(meeting(frames: [frame]).transcriptText.contains("Secret slide"))
    }

    func testAMeetingWithCapturesRoundTripsAndOldOnesDecode() throws {
        let frame = ScreenFrame(at: Date(timeIntervalSince1970: 1_000_020), text: "Slide", sourceApp: "Zoom", fileName: "a.jpg")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(meeting(frames: [frame]))
        let back = try decoder.decode(Meeting.self, from: data)
        XCTAssertEqual(back.frames, [frame])

        let old = try encoder.encode(meeting(frames: nil))
        XCTAssertNil(try decoder.decode(Meeting.self, from: old).frames)
    }

    // MARK: - Reading a real image

    func testTextIsReadOffARenderedSlide() async throws {
        let size = NSSize(width: 1200, height: 700)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.darkGray]
        ("Quarterly revenue" as NSString).draw(at: NSPoint(x: 80, y: 540), withAttributes: title)
        ("Support adoption 70 percent" as NSString).draw(at: NSPoint(x: 80, y: 400), withAttributes: body)
        ("Legal summary due Thursday" as NSString).draw(at: NSPoint(x: 80, y: 320), withAttributes: body)
        image.unlockFocus()
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        let text = try await ScreenTextReader.text(in: cg)
        print("=== SCREEN TEXT: \(text.replacingOccurrences(of: "\n", with: " / ")) ===")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Quarterly revenue"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Thursday"))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first?.localizedCaseInsensitiveContains("Quarterly"), true, "the title should come first")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seal-slide-\(UUID().uuidString).jpg")
        try ScreenTextReader.writeJPEG(cg, to: url, maxWidth: 800)
        let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(bytes, 5_000)
        XCTAssertLessThan(bytes, 400_000)
        try? FileManager.default.removeItem(at: url)
    }
}
