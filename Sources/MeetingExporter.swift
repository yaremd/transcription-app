import AppKit
import UniformTypeIdentifiers

/// Exports a meeting to Markdown (clipboard or file) or PDF. The user's data
/// only ever leaves the app when they explicitly choose to export it.
enum MeetingExporter {
    static func markdown(_ m: Meeting) -> String {
        var s = "# \(m.title)\n\n"
        s += "_\(m.date.formatted(date: .abbreviated, time: .shortened))_\n\n"
        if let tags = m.tags, !tags.isEmpty {
            s += "Tags: \(tags.joined(separator: ", "))\n\n"
        }
        if m.hasNotes {
            s += "## Notes\n\n\(m.notes)\n\n"
        }
        s += "## Transcript\n\n"
        for line in m.lines {
            s += "**\(line.speaker):** \(line.text)\n\n"
        }
        return s
    }

    static func copyMarkdown(_ m: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(m), forType: .string)
    }

    static func exportMarkdown(_ m: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(m) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(m).data(using: .utf8)?.write(to: url)
    }

    static func exportPDF(_ m: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(m) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pageWidth: CGFloat = 540
        let inset: CGFloat = 32

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 100))
        textView.appearance = NSAppearance(named: .aqua)   // force light rendering for the PDF
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: inset, height: inset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: pageWidth - inset * 2, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed(m))

        if let container = textView.textContainer, let lm = textView.layoutManager {
            lm.ensureLayout(for: container)
            let used = lm.usedRect(for: container).size
            textView.frame = NSRect(x: 0, y: 0, width: pageWidth, height: used.height + inset * 2)
        }

        let pdf = textView.dataWithPDF(inside: textView.bounds)
        try? pdf.write(to: url)
    }

    private static func attributed(_ m: Meeting) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, size: CGFloat, bold: Bool = false,
                 color: NSColor = .black, spacingAfter: CGFloat = 6) {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = spacingAfter
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            out.append(NSAttributedString(string: text + "\n",
                                          attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        add(m.title, size: 20, bold: true, spacingAfter: 2)
        add(m.date.formatted(date: .abbreviated, time: .shortened), size: 11, color: .darkGray, spacingAfter: 10)
        if let tags = m.tags, !tags.isEmpty {
            add("Tags: " + tags.joined(separator: ", "), size: 11, color: .darkGray, spacingAfter: 12)
        }
        if m.hasNotes {
            add("Notes", size: 15, bold: true)
            add(m.notes, size: 12, spacingAfter: 14)
        }
        add("Transcript", size: 15, bold: true)
        for line in m.lines {
            add("\(line.speaker):", size: 11, bold: true, color: .darkGray, spacingAfter: 1)
            add(line.text, size: 12, spacingAfter: 8)
        }
        return out
    }

    private static func filename(_ m: Meeting) -> String {
        let base = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? "Meeting" : base)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
