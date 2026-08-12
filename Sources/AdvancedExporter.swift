import AppKit
import UniformTypeIdentifiers

/// The Pro export formats (YAR-104): Word's OOXML and SRT/VTT subtitles.
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
