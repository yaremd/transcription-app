import AppKit
import UniformTypeIdentifiers

/// The Pro export formats (YAR-104): Word's OOXML, SRT/VTT subtitles, and
/// Obsidian-flavoured Markdown.
/// Everything is generated in-process — a .docx is a zip of three XML parts,
/// and this writes both the XML and the zip by hand rather than pull in a
/// dependency for what amounts to headers and a checksum. Like every export,
/// data only leaves the app when the user explicitly asks.
enum AdvancedExporter {

    // MARK: - Word (.docx)

    static func exportDocx(_ m: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(m) + ".docx"
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? docxData(m).write(to: url)
    }

    /// The complete .docx file: a stored (uncompressed) zip of the three parts
    /// Word requires. Word and Pages both open minimal OOXML happily.
    static func docxData(_ m: Meeting) -> Data {
        var zip = StoredZip()
        zip.add(path: "[Content_Types].xml", text: contentTypesXML)
        zip.add(path: "_rels/.rels", text: relsXML)
        zip.add(path: "word/document.xml", text: documentXML(m))
        return zip.finish()
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    /// The document body. Direct run formatting only (no styles part needed):
    /// headings are bold at a larger size, speaker names bold, everything else
    /// plain. The notes' light Markdown is flattened the same way the PDF
    /// export flattens it — headings by #-depth, bullets to the bullet glyph.
    static func documentXML(_ m: Meeting) -> String {
        var paragraphs: [String] = []
        paragraphs.append(paragraph([run(m.title, bold: true, halfPointSize: 40)]))
        paragraphs.append(paragraph([run(m.date.formatted(date: .abbreviated, time: .shortened),
                                         halfPointSize: 20, gray: true)]))
        if let tags = m.tags, !tags.isEmpty {
            paragraphs.append(paragraph([run("Tags: " + tags.joined(separator: ", "),
                                             halfPointSize: 20, gray: true)]))
        }
        if m.hasNotes {
            paragraphs.append(paragraph([]))
            paragraphs.append(paragraph([run("Notes", bold: true, halfPointSize: 30)]))
            for raw in m.notes.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { paragraphs.append(paragraph([])); continue }
                if line.hasPrefix("#") {
                    let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    paragraphs.append(paragraph([run(text, bold: true, halfPointSize: 26)]))
                } else {
                    var text = line
                    var bullet = false
                    while let first = text.first, "-*•".contains(first) {
                        bullet = true
                        text.removeFirst()
                        text = text.trimmingCharacters(in: .whitespaces)
                    }
                    text = text.replacingOccurrences(of: "**", with: "")
                    paragraphs.append(paragraph([run((bullet ? "•  " : "") + text, halfPointSize: 22)]))
                }
            }
        }
        paragraphs.append(paragraph([]))
        paragraphs.append(paragraph([run("Transcript", bold: true, halfPointSize: 30)]))
        for line in m.lines {
            paragraphs.append(paragraph([
                run(m.displayLabel(for: line) + ":  ", bold: true, halfPointSize: 22, gray: true),
                run(line.text, halfPointSize: 22),
            ]))
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(paragraphs.joined())</w:body>
        </w:document>
        """
    }

    private static func paragraph(_ runs: [String]) -> String {
        "<w:p>" + runs.joined() + "</w:p>"
    }

    private static func run(_ text: String, bold: Bool = false,
                            halfPointSize: Int = 22, gray: Bool = false) -> String {
        var props = ""
        if bold { props += "<w:b/>" }
        if gray { props += "<w:color w:val=\"595959\"/>" }
        props += "<w:sz w:val=\"\(halfPointSize)\"/>"
        return "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(escaped(text))</w:t></w:r>"
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Subtitles (.srt / .vtt)

    static func exportSRT(_ m: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(m) + ".srt"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? srt(m).data(using: .utf8)?.write(to: url)
    }

    static func exportVTT(_ m: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(m) + ".vtt"
        panel.allowedContentTypes = [UTType(filenameExtension: "vtt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? vtt(m).data(using: .utf8)?.write(to: url)
    }

    static func srt(_ m: Meeting) -> String {
        cues(m).enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start, comma: true)) --> \(stamp(cue.end, comma: true))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ m: Meeting) -> String {
        "WEBVTT\n\n" + cues(m).map { cue in
            "\(stamp(cue.start, comma: false)) --> \(stamp(cue.end, comma: false))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// One cue per transcript line, on the recording's own timeline. Lines
    /// from before timing existed (old meetings) get estimated slots after
    /// the previous cue — a subtitle roughly where the words are beats
    /// refusing the whole export.
    static func cues(_ m: Meeting) -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        var cursor: TimeInterval = 0
        return m.lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let start = line.start ?? cursor
            let estimated = max(1.5, Double(text.count) / 15)
            let end = line.end ?? (start + estimated)
            cursor = max(cursor, end) + 0.05
            return (start, end, "\(m.displayLabel(for: line)): \(text)")
        }
    }

    /// "HH:MM:SS,mmm" (SRT) or "HH:MM:SS.mmm" (VTT). Rounded on total
    /// milliseconds — truncating the fractional part alone turns 1.2 s into
    /// .199 through binary float representation.
    static func stamp(_ seconds: TimeInterval, comma: Bool) -> String {
        let totalMillis = max(0, Int((seconds * 1000).rounded()))
        let hours = totalMillis / 3_600_000
        let minutes = totalMillis / 60_000 % 60
        let secs = totalMillis / 1000 % 60
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, comma ? "," : ".", millis)
    }

    // MARK: - Obsidian Markdown (.md)

    /// Markdown for a vault rather than for a reader. Three things separate it
    /// from the plain export: YAML frontmatter so the meeting becomes queryable
    /// properties, `[[wikilinks]]` on named people so every meeting with Maya
    /// backlinks to Maya, and action items as real checkboxes so they show up
    /// in Obsidian's task views. No H1 — the filename is the note's title, and
    /// repeating it is the thing vault users complain about.
    static func exportObsidian(_ m: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(m) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? obsidianMarkdown(m).data(using: .utf8)?.write(to: url)
    }

    static func obsidianMarkdown(_ m: Meeting) -> String {
        var s = "---\n"
        s += "title: \(yamlQuoted(m.title.isEmpty ? "Meeting" : m.title))\n"
        s += "date: \(isoDate(m.date))\n"
        s += "time: \(yamlQuoted(isoTime(m.date)))\n"
        s += "duration_minutes: \(max(0, Int((m.duration / 60).rounded())))\n"
        if !m.language.isEmpty { s += "language: \(yamlQuoted(m.language))\n" }

        // Quoted, because an unquoted [[Name]] parses as a nested YAML
        // sequence rather than a link. Obsidian resolves the quoted form.
        let people = attendees(m)
        if !people.isEmpty {
            s += "attendees:\n"
            for name in people { s += "  - \(yamlQuoted("[[\(wikilinkSafe(name))]]"))\n" }
        }

        var tags = ["meeting"]
        tags += (m.tags ?? []).compactMap(obsidianTag)
        if let folder = m.folder.flatMap(obsidianTag) { tags.append(folder) }
        var seenTags = Set<String>()
        s += "tags:\n"
        for tag in tags where seenTags.insert(tag).inserted { s += "  - \(tag)\n" }
        s += "---\n\n"

        if m.hasNotes { s += "## Notes\n\n\(m.notes)\n\n" }

        let items = m.actionItems ?? []
        if !items.isEmpty {
            s += "## Action items\n\n"
            for item in items { s += "- [\(item.done ? "x" : " ")] \(item.text)\n" }
            s += "\n"
        }

        s += "## Transcript\n\n"
        for line in m.lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let label = m.displayLabel(for: line)
            let who = isRealName(label) ? "[[\(wikilinkSafe(label))]]" : label
            s += "**\(who):** \(text)\n\n"
        }
        return s
    }

    /// Calendar attendees when we have them; otherwise whoever actually spoke
    /// and has a real name. "You" and an unnamed "Others" are not people a
    /// vault wants a note for.
    static func attendees(_ m: Meeting) -> [String] {
        if let invited = m.calendarAttendees?.compactMap(cleanName), !invited.isEmpty {
            return dedupePreservingOrder(invited)
        }
        return dedupePreservingOrder(
            m.lines.map { m.displayLabel(for: $0) }.filter(isRealName).compactMap(cleanName)
        )
    }

    /// True for a name worth linking. The raw fallback labels are roles, not
    /// people, and "Speaker 2" is a placeholder the user hasn't named yet.
    private static func isRealName(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "You", trimmed != "Others" else { return false }
        return !trimmed.hasPrefix("Speaker ")
    }

    private static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dedupePreservingOrder(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Characters that would end a wikilink early or split it into an alias.
    private static func wikilinkSafe(_ name: String) -> String {
        name.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "^", with: "")
    }

    /// An Obsidian tag can't hold whitespace or a leading #, and a tag that is
    /// only digits is not a tag at all — those are dropped rather than mangled.
    private static func obsidianTag(_ raw: String) -> String? {
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        guard !collapsed.isEmpty, collapsed.contains(where: { !$0.isNumber }) else { return nil }
        return collapsed
    }

    /// Double-quoted YAML: only the backslash and the quote need escaping
    /// inside one, which keeps colons, dashes and em-dashes in titles safe.
    static func yamlQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        + "\""
    }

    /// Fixed-format, POSIX locale. `Date.formatted` follows the user's locale,
    /// which on a Ukrainian Mac writes a date Obsidian won't read as a date.
    static func isoDate(_ date: Date) -> String { fixed("yyyy-MM-dd", date) }
    static func isoTime(_ date: Date) -> String { fixed("HH:mm", date) }

    private static func fixed(_ format: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func filename(_ m: Meeting) -> String {
        let base = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? "Meeting" : base)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

// MARK: - Stored zip

/// A minimal zip writer: stored entries (no compression — the parts are tiny),
/// CRC-32, central directory, end record. Exactly what the OOXML container
/// needs and nothing more.
struct StoredZip {
    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var out = Data()
    private var entries: [Entry] = []

    mutating func add(path: String, text: String) {
        add(path: path, data: Data(text.utf8))
    }

    mutating func add(path: String, data: Data) {
        let name = Data(path.utf8)
        let crc = Self.crc32(data)
        let offset = UInt32(out.count)
        out.append(u32: 0x04034B50)            // local file header
        out.append(u16: 20)                    // version needed
        out.append(u16: 0)                     // flags
        out.append(u16: 0)                     // method: stored
        out.append(u16: 0); out.append(u16: 0) // time, date
        out.append(u32: crc)
        out.append(u32: UInt32(data.count))    // compressed size (== raw)
        out.append(u32: UInt32(data.count))
        out.append(u16: UInt16(name.count))
        out.append(u16: 0)                     // extra length
        out.append(name)
        out.append(data)
        entries.append(Entry(path: path, data: data, crc: crc, offset: offset))
    }

    func finish() -> Data {
        var result = out
        let directoryStart = UInt32(result.count)
        for entry in entries {
            let name = Data(entry.path.utf8)
            result.append(u32: 0x02014B50)     // central directory header
            result.append(u16: 20)             // version made by
            result.append(u16: 20)             // version needed
            result.append(u16: 0)              // flags
            result.append(u16: 0)              // method: stored
            result.append(u16: 0); result.append(u16: 0)
            result.append(u32: entry.crc)
            result.append(u32: UInt32(entry.data.count))
            result.append(u32: UInt32(entry.data.count))
            result.append(u16: UInt16(name.count))
            result.append(u16: 0)              // extra
            result.append(u16: 0)              // comment
            result.append(u16: 0)              // disk
            result.append(u16: 0)              // internal attrs
            result.append(u32: 0)              // external attrs
            result.append(u32: entry.offset)
            result.append(name)
        }
        let directorySize = UInt32(result.count) - directoryStart
        result.append(u32: 0x06054B50)         // end of central directory
        result.append(u16: 0); result.append(u16: 0)
        result.append(u16: UInt16(entries.count))
        result.append(u16: UInt16(entries.count))
        result.append(u32: directorySize)
        result.append(u32: directoryStart)
        result.append(u16: 0)                  // comment length
        return result
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func append(u32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
