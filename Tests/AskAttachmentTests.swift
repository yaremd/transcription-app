import XCTest
import AppKit
import PDFKit
@testable import Seal

/// A file put beside a question is read into text on the Mac — whatever it
/// is — cut to what the model can take, and handed over under its name.
final class AskAttachmentTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        try file(name, Data(text.utf8))
    }

    // MARK: - Reading

    func testPlainTextIsReadCleaned() async throws {
        let url = try file("plan.md", "# Plan  \r\n\r\n\r\n\r\nShip Friday.\t\r\n  indented stays\n\u{0007}Done.\n\n")
        let text = try await AskAttachmentReader.read(url)
        XCTAssertEqual(text, "# Plan\n\nShip Friday.\n  indented stays\nDone.")
    }

    func testALongFileIsCutAndSaysSo() async throws {
        let url = try file("log.txt", String(repeating: "word ", count: 6000))   // 30,000 characters
        let text = try await AskAttachmentReader.read(url)
        XCTAssertTrue(text.hasPrefix("word word"))
        XCTAssertTrue(text.contains("[… cut here: "), "the cut is announced to the model")
        XCTAssertLessThan(text.count, AskAttachmentReader.maxCharactersPerFile + 80)
    }

    func testRTFIsReadThroughAppKit() async throws {
        let rich = NSAttributedString(string: "Budget is 1.2M, owner Maria.")
        let data = try rich.data(from: NSRange(location: 0, length: rich.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let text = try await AskAttachmentReader.read(try file("budget.rtf", data))
        XCTAssertEqual(text, "Budget is 1.2M, owner Maria.")
    }

    func testWordDocumentIsReadThroughAppKit() async throws {
        let rich = NSAttributedString(string: "Rollout: support first, then sales.")
        let data = try rich.data(from: NSRange(location: 0, length: rich.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let text = try await AskAttachmentReader.read(try file("rollout.docx", data))
        XCTAssertTrue(text.contains("support first, then sales"), "got: \(text)")
        XCTAssertEqual(AskAttachmentReader.kind(of: scratch.appendingPathComponent("rollout.docx")), .document)
    }

    func testPDFTextLayerIsRead() async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Legal summary due Thursday",
                               attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let text = try await AskAttachmentReader.read(try file("legal.pdf", data as Data))
        XCTAssertTrue(text.contains("Thursday"), "got: \(text)")
    }

    func testAnImageIsReadWithVision() async throws {
        let image = NSImage(size: NSSize(width: 900, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("MEETING AGENDA 2026" as NSString).draw(
                at: NSPoint(x: 40, y: 80),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black])
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = try file("agenda.png", png)
        XCTAssertEqual(AskAttachmentReader.kind(of: url), .image)
        let text = try await AskAttachmentReader.read(url)
        XCTAssertTrue(text.uppercased().contains("AGENDA"), "got: \(text)")
    }

    func testAMovieIsRefusedWithWhatCanBeRead() async throws {
        let url = try file("clip.mov", Data(repeating: 0, count: 64))
        do {
            _ = try await AskAttachmentReader.read(url)
            XCTFail("a movie has no text to read")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("can't be read into text"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("PDF"), "the refusal says what works")
        }
    }

    func testBinaryWithNoKnownTypeIsRefused() async throws {
        var bytes = Data(repeating: 0x41, count: 100)
        bytes.append(contentsOf: [0, 0, 0, 0])
        let url = try file("blob.xyz", bytes)
        await XCTAssertThrowsErrorAsync(try await AskAttachmentReader.read(url))
    }

    // MARK: - What the model gets

    func testThePromptBlockNamesEachFile() {
        let block = AskDocument.promptBlock([AskDocument(name: "plan.md", text: "Ship Friday."),
                                            AskDocument(name: "notes.pdf", text: "Budget 1.2M")])
        XCTAssertEqual(block, "ATTACHED \"plan.md\":\nShip Friday.\n\nATTACHED \"notes.pdf\":\nBudget 1.2M")
        XCTAssertEqual(AskDocument.promptBlock([]), "")
    }

    func testOneQuestionsFilesShareABudget() {
        let big = String(repeating: "x", count: AskAttachmentReader.maxCharactersPerFile)
        var one = AskAttachment(name: "a.txt", kind: .text); one.state = .ready(big)
        var two = AskAttachment(name: "b.txt", kind: .text); two.state = .ready(big)
        var three = AskAttachment(name: "c.txt", kind: .text); three.state = .ready(big)
        var failed = AskAttachment(name: "d.mov", kind: .text); failed.state = .failed("no")
        let reading = AskAttachment(name: "e.txt", kind: .text)
        let documents = AskAttachmentReader.documents(from: [one, two, three, failed, reading])
        XCTAssertEqual(documents.map(\.name), ["a.txt", "b.txt"], "the third crosses the line; the rest never read")
        XCTAssertEqual(documents[0].text.count, AskAttachmentReader.maxCharactersPerFile)
        XCTAssertEqual(documents[1].text.count, AskAttachmentReader.maxCharactersPerFile)
    }

    func testTheFileThatCrossesTheLineIsCutThere() {
        let half = AskAttachmentReader.maxCharactersPerQuestion / 2
        var one = AskAttachment(name: "a.txt", kind: .text); one.state = .ready(String(repeating: "a", count: half + 100))
        var two = AskAttachment(name: "b.txt", kind: .text); two.state = .ready(String(repeating: "b", count: half))
        let documents = AskAttachmentReader.documents(from: [one, two])
        XCTAssertEqual(documents.count, 2)
        XCTAssertTrue(documents[1].text.hasPrefix(String(repeating: "b", count: half - 100)))
        XCTAssertTrue(documents[1].text.contains("[… cut here: 100 more characters not shown]"))
    }

    // MARK: - Keys

    func testReturnSendsAndAModifierBreaksTheLine() {
        XCTAssertEqual(ComposerKey.action(forReturnWith: []), .send)
        XCTAssertEqual(ComposerKey.action(forReturnWith: [.command]), .send)
        XCTAssertEqual(ComposerKey.action(forReturnWith: [.shift]), .newline)
        XCTAssertEqual(ComposerKey.action(forReturnWith: [.option]), .newline)
        XCTAssertEqual(ComposerKey.action(forReturnWith: [.control]), .newline)
        XCTAssertEqual(ComposerKey.action(forReturnWith: [.shift, .command]), .newline)
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // expected
    }
}
