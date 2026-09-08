import XCTest
@testable import Seal

/// The Pro export formats (YAR-104) and custom templates (YAR-103): pure
/// builders, tested on their output bytes and text — no save panels involved.
final class AdvancedExportTests: XCTestCase {

    private func meeting(lines: [StoredLine], notes: String = "") -> Meeting {
        Meeting(title: "Vendor call", date: Date(timeIntervalSince1970: 1_800_000_000),
                duration: 600, language: "en", lines: lines, notes: notes)
    }

    // MARK: - Subtitles

    func testSRTUsesRealTimingsAndSpeakerLabels() {
        let m = meeting(lines: [
            StoredLine(speaker: "You", text: "Hello there.", start: 1.5, end: 3.0),
            StoredLine(speaker: "Others", text: "Hi, how are you?", start: 3.25, end: 5.75),
        ])
        let srt = AdvancedExporter.srt(m)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:01,500 --> 00:00:03,000\nYou: Hello there.\n"))
        XCTAssertTrue(srt.contains("2\n00:00:03,250 --> 00:00:05,750\nOthers: Hi, how are you?"))
    }

    func testVTTHasHeaderAndDotSeparators() {
        let m = meeting(lines: [StoredLine(speaker: "You", text: "Okay.", start: 0.5, end: 1.2)])
        let vtt = AdvancedExporter.vtt(m)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:00.500 --> 00:00:01.200"))
    }

    /// Meetings saved before per-line timing existed still export: estimated
    /// slots follow the previous cue instead of stacking at zero.
    func testUntimedLinesGetSequentialEstimatedSlots() {
        let m = meeting(lines: [
            StoredLine(speaker: "You", text: "First line here."),
            StoredLine(speaker: "Others", text: "Second line follows."),
        ])
        let cues = AdvancedExporter.cues(m)
        XCTAssertEqual(cues.count, 2)
        XCTAssertGreaterThan(cues[1].start, cues[0].end, "cue two starts after cue one ends")
    }

    func testEmptyLinesAreSkippedAndHourRollsOver() {
        let m = meeting(lines: [
            StoredLine(speaker: "You", text: "   "),
            StoredLine(speaker: "You", text: "Late line.", start: 3661.05, end: 3663.0),
        ])
        let cues = AdvancedExporter.cues(m)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(AdvancedExporter.stamp(3661.05, comma: true), "01:01:01,050")
    }

    /// Identified far-side voices label their cues the way the transcript
    /// shows them — the named speaker, not the raw "Others".
    func testCuesUseDisplayLabels() {
        var m = meeting(lines: [StoredLine(speaker: "Others", text: "Hello.", start: 0, end: 1, voice: "S1")])
        m.speakerNames = ["S1": "Kumar"]
        XCTAssertEqual(AdvancedExporter.cues(m).first?.text, "Kumar: Hello.")
    }

    // MARK: - Word

    func testDocxIsAWellFormedStoredZipWithTheThreeParts() {
        let m = meeting(lines: [StoredLine(speaker: "You", text: "Hello.")], notes: "# Summary\n- One point")
        let data = AdvancedExporter.docxData(m)
        // Zip signatures: local header at byte 0, end-of-central-directory present.
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertNotNil(data.range(of: Data([0x50, 0x4B, 0x05, 0x06])))
        for part in ["[Content_Types].xml", "_rels/.rels", "word/document.xml"] {
            XCTAssertNotNil(data.range(of: Data(part.utf8)), "\(part) missing")
        }
    }

    func testDocumentXMLEscapesAndStructures() {
        var m = meeting(lines: [StoredLine(speaker: "You", text: "Tokens < 1000 & rising")],
                        notes: "# Key <points>\n- First & second")
        m.title = "Q&A session"
        let xml = AdvancedExporter.documentXML(m)
        XCTAssertTrue(xml.contains("Q&amp;A session"))
        XCTAssertTrue(xml.contains("Key &lt;points&gt;"))
        XCTAssertTrue(xml.contains("•  First &amp; second"))
        XCTAssertTrue(xml.contains("Tokens &lt; 1000 &amp; rising"))
        XCTAssertTrue(xml.contains("<w:body>") && xml.contains("</w:body>"))
        XCTAssertFalse(xml.contains("**"), "markdown bold markers are flattened")
    }

    func testZipCRC32MatchesKnownVector() {
        // The classic test vector: crc32("123456789") == 0xCBF43926.
        XCTAssertEqual(StoredZip.crc32(Data("123456789".utf8)), 0xCBF43926)
    }

    // MARK: - Custom templates (YAR-103)

    func testCustomTemplateLifecyclePersistsAndResolves() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemplateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("templates.json")

        let store = CustomTemplateStore(fileURL: file)
        let created = store.add(name: "Therapy session",
                                sections: ["Summary", "Themes", "Homework"],
                                guidance: "Clinical, neutral tone.")
        XCTAssertTrue(created.isCustom)

        store.update(NotesTemplate(id: created.id, name: "Supervision",
                                   sections: ["Summary"], guidance: ""))
        let reloaded = CustomTemplateStore(fileURL: file)
        XCTAssertEqual(reloaded.templates.count, 1)
        XCTAssertEqual(reloaded.templates.first?.name, "Supervision")

        reloaded.remove(id: created.id)
        XCTAssertTrue(CustomTemplateStore(fileURL: file).templates.isEmpty)
    }

    func testBuiltInsAreNeverCustomAndByIDFallsBack() {
        for template in NotesTemplate.all {
            XCTAssertFalse(template.isCustom)
        }
        // An unknown (deleted) id falls back to General rather than breaking
        // the meeting that remembers it.
        XCTAssertEqual(NotesTemplate.byID("custom-DELETED").id, NotesTemplate.general.id)
        XCTAssertEqual(NotesTemplate.byID("sales").id, "sales")
    }

    // MARK: - Obsidian Markdown

    func testObsidianFrontmatterIsWellFormedAndOrdered() {
        var m = meeting(lines: [StoredLine(speaker: "You", text: "Hello.")], notes: "A point")
        m.tags = ["Product Launch", "q3"]
        let md = AdvancedExporter.obsidianMarkdown(m)

        XCTAssertTrue(md.hasPrefix("---\n"), "frontmatter must open the file or Obsidian ignores it")
        let body = md.components(separatedBy: "\n---\n\n")
        XCTAssertEqual(body.count, 2, "exactly one closing delimiter")
        XCTAssertTrue(body[0].contains("title: \"Vendor call\""))
        XCTAssertTrue(body[0].contains("duration_minutes: 10"))
        // A spaced tag would break Obsidian's parser; it gets hyphenated.
        XCTAssertTrue(body[0].contains("  - Product-Launch"))
        XCTAssertTrue(body[0].contains("  - meeting"))
    }

    /// `Date.formatted` follows the user's locale. On a Ukrainian Mac that
    /// writes a date Obsidian will not read as a date, so the exporter pins
    /// the formatter to POSIX.
    func testDatesAreISORegardlessOfDeviceLocale() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AdvancedExporter.isoDate(date).count, 10)
        XCTAssertTrue(AdvancedExporter.isoDate(date).hasPrefix("2027-"))
        XCTAssertEqual(AdvancedExporter.isoTime(date).count, 5)
        XCTAssertTrue(AdvancedExporter.isoDate(date).allSatisfy { $0.isNumber || $0 == "-" })
    }

    func testYAMLQuotingSurvivesQuotesBackslashesAndColons() {
        XCTAssertEqual(AdvancedExporter.yamlQuoted("Acme: a \"big\" win"), "\"Acme: a \\\"big\\\" win\"")
        XCTAssertEqual(AdvancedExporter.yamlQuoted("path\\to"), "\"path\\\\to\"")
        // A newline inside a double-quoted scalar would end the value early.
        XCTAssertFalse(AdvancedExporter.yamlQuoted("two\nlines").contains("\n"))
    }

    /// The point of the format: every meeting with Maya backlinks to Maya.
    /// Role labels are not people and must stay plain text.
    func testNamedSpeakersAreWikilinkedButRolesAreNot() {
        var m = meeting(lines: [
            StoredLine(speaker: "You", text: "Morning."),
            StoredLine(speaker: "Others", text: "Morning.", voice: "S1"),
            StoredLine(speaker: "Others", text: "Anything else?", voice: "S2"),
        ])
        m.speakerNames = ["S1": "Maya"]
        let md = AdvancedExporter.obsidianMarkdown(m)

        XCTAssertTrue(md.contains("**[[Maya]]:** Morning."))
        XCTAssertTrue(md.contains("**You:** Morning."))
        XCTAssertFalse(md.contains("[[You]]"), "a role is not a person")
        XCTAssertFalse(md.contains("[[Speaker 2]]"), "an unnamed voice is a placeholder")
        // Frontmatter links must be quoted or YAML reads [[..]] as a sequence.
        XCTAssertTrue(md.contains("  - \"[[Maya]]\""))
    }

    func testWikilinkSyntaxInANameCannotEscapeTheLink() {
        var m = meeting(lines: [StoredLine(speaker: "Others", text: "Hi.", voice: "S1")])
        m.speakerNames = ["S1": "Bo]] | #x"]
        let md = AdvancedExporter.obsidianMarkdown(m)
        XCTAssertTrue(md.contains("[[Bo)) - x]]"))
        XCTAssertFalse(md.contains("]] |"))
    }

    func testActionItemsBecomeObsidianCheckboxes() {
        var m = meeting(lines: [StoredLine(speaker: "You", text: "Done.")])
        m.actionItems = [ActionItem(text: "Run QA"), ActionItem(text: "Send note", done: true)]
        let md = AdvancedExporter.obsidianMarkdown(m)
        XCTAssertTrue(md.contains("- [ ] Run QA"))
        XCTAssertTrue(md.contains("- [x] Send note"))
    }

    /// The filename carries the title in a vault, so an H1 repeating it is
    /// the duplication Obsidian users complain about.
    func testNoLevelOneHeadingAndCalendarAttendeesWin() {
        var m = meeting(lines: [StoredLine(speaker: "Others", text: "Hi.", voice: "S1")], notes: "Note")
        m.speakerNames = ["S1": "Maya"]
        m.calendarAttendees = ["Priya Raman", "  "]
        let md = AdvancedExporter.obsidianMarkdown(m)

        XCTAssertFalse(md.contains("\n# "), "no duplicate H1")
        XCTAssertTrue(md.contains("  - \"[[Priya Raman]]\""), "calendar list wins over speakers")
        XCTAssertFalse(md.contains("[[  ]]"), "blank attendee dropped")
        XCTAssertTrue(md.contains("## Notes"))
        XCTAssertTrue(md.contains("## Transcript"))
    }

    func testEmptyMeetingStillProducesValidFrontmatter() {
        let m = Meeting(title: "", date: Date(timeIntervalSince1970: 0),
                        duration: 0, language: "", lines: [], notes: "")
        let md = AdvancedExporter.obsidianMarkdown(m)
        XCTAssertTrue(md.contains("title: \"Meeting\""), "untitled falls back rather than emitting an empty key")
        XCTAssertFalse(md.contains("attendees:"), "no empty YAML list")
        XCTAssertFalse(md.contains("language:"))
        XCTAssertTrue(md.contains("  - meeting"), "always at least one tag")
    }
}
