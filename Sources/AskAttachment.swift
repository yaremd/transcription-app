import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A file put beside a question. It is read into text on the Mac the moment
/// it is attached — a PDF's text layer, a Word file's words, the text on an
/// image — so the model sees it the way it sees the transcript. The file is
/// never copied or kept, and like the question it lives in memory only.
struct AskAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Plain text, Markdown, code, data files.
        case text
        /// PDF, Word, RTF, HTML.
        case document
        /// A picture; the text on it is read.
        case image
        /// What was on the screen when it was attached.
        case screen

        var symbol: String {
            switch self {
            case .text: return "doc.plaintext"
            case .document: return "doc.richtext"
            case .image: return "photo"
            case .screen: return "macwindow"
            }
        }
    }

    enum State: Equatable {
        /// Being read; the question waits for it.
        case reading
        /// Read: this is what goes with the question.
        case ready(String)
        /// Couldn't be read, and why. It stays beside the question until
        /// removed, and is left out when the question is sent.
        case failed(String)
    }

    let id = UUID()
    var name: String
    var kind: Kind
    var state: State = .reading

    var text: String? {
        if case .ready(let text) = state { return text }
        return nil
    }
    var isReading: Bool { state == .reading }
    var failure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}

/// What of an attachment reaches the model: its name and its text.
struct AskDocument: Equatable {
    let name: String
    let text: String

    /// The attachments as they go before the question, each under its name
    /// so the model can tell the files apart and say which one it is quoting.
    static func promptBlock(_ documents: [AskDocument]) -> String {
        documents.map { "ATTACHED \"\($0.name)\":\n\($0.text)" }.joined(separator: "\n\n")
    }
}

/// Reads an attached file into text, on the Mac, with nothing leaving it.
enum AskAttachmentReader {
    struct ReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// How much of one file the model is shown. 12,000 characters is about
    /// four pages — roughly 3,000 tokens, which the 3B model on an 8 GB Mac
    /// still reads in a few seconds on top of an hour's transcript.
    static let maxCharactersPerFile = 12_000
    /// How much all of one question's files may add up to.
    static let maxCharactersPerQuestion = 24_000
    static let maxAttachments = 5

    static let readableSummary = "Seal can read text, Markdown, PDF, Word, RTF, HTML, and images (the text on them)."

    /// What the open panel offers.
    static var openableTypes: [UTType] {
        var types: [UTType] = [.plainText, .utf8PlainText, .text, .sourceCode, .json, .xml, .yaml,
                               .commaSeparatedText, .tabSeparatedText, .html, .rtf, .rtfd, .pdf, .image]
        for ext in ["md", "markdown", "docx", "doc", "odt", "log"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// Word-processor formats AppKit reads for us, by the type they come as.
    private static let richTypes: [(UTType, NSAttributedString.DocumentType)] = {
        var list: [(UTType, NSAttributedString.DocumentType)] = [(.rtf, .rtf), (.rtfd, .rtfd)]
        if let docx = UTType(filenameExtension: "docx") { list.append((docx, .officeOpenXML)) }
        if let doc = UTType(filenameExtension: "doc") { list.append((doc, .docFormat)) }
        if let odt = UTType(filenameExtension: "odt") { list.append((odt, .openDocument)) }
        return list
    }()

    static func kind(of url: URL) -> AskAttachment.Kind {
        let type = contentType(of: url)
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) || type.conforms(to: .html)
            || richTypes.contains(where: { type.conforms(to: $0.0) }) { return .document }
        return .text
    }

    /// The file as text: cleaned, and cut to `maxCharactersPerFile`.
    static func read(_ url: URL) async throws -> String {
        let type = contentType(of: url)
        let raw: String
        if type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ReadError(message: "Couldn't open the image.")
            }
            raw = try await ScreenTextReader.text(in: image)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ReadError(message: "No readable text on this image.")
            }
        } else if type.conforms(to: .pdf) {
            raw = try await pdfText(url)
        } else if type.conforms(to: .html) {
            // AppKit's HTML importer insists on the main thread.
            raw = try await MainActor.run { try attributedText(url, as: .html) }
        } else if let rich = richTypes.first(where: { type.conforms(to: $0.0) }) {
            raw = try attributedText(url, as: rich.1)
        } else if type.conforms(to: .text) {
            raw = try plainText(url, declaredText: true)
        } else if type.conforms(to: .audiovisualContent) || type.conforms(to: .archive)
                    || type.conforms(to: .application) || type.conforms(to: .directory) {
            let what = type.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "This"
            throw ReadError(message: "\(what) can't be read into text. \(readableSummary)")
        } else {
            raw = try plainText(url, declaredText: false)
        }
        let text = cleaned(raw)
        guard !text.isEmpty else { throw ReadError(message: "Nothing readable in this file.") }
        return clipped(text)
    }

    /// The documents a question carries, within the question's budget: files
    /// go in the order they were attached, and the one that crosses the line
    /// is cut there.
    static func documents(from attachments: [AskAttachment]) -> [AskDocument] {
        var remaining = maxCharactersPerQuestion
        var out: [AskDocument] = []
        for attachment in attachments {
            guard let text = attachment.text, remaining > 0 else { continue }
            let count = text.count
            out.append(AskDocument(name: attachment.name, text: count > remaining ? clipped(text, to: remaining) : text))
            remaining -= min(count, remaining)
        }
        return out
    }

    // MARK: - Text hygiene

    /// Line endings normalised, control characters and Word's object markers
    /// dropped, trailing spaces trimmed, never more than one blank line in a
    /// row. Indentation is kept — code and tables need it.
    static func cleaned(_ raw: String) -> String {
        let unified = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0B}", with: "\n")      // Word's soft line break
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")      // an embedded picture
        let scalars = unified.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        var lines: [String] = []
        var blankRun = 0
        for line in String(String.UnicodeScalarView(scalars)).components(separatedBy: "\n") {
            let kept = line.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
            if kept.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            lines.append(kept)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first `limit` characters, and a line saying how much was left out.
    static func clipped(_ text: String, to limit: Int = maxCharactersPerFile) -> String {
        let count = text.count
        guard count > limit else { return text }
        return String(text.prefix(limit)) + "\n[… cut here: \(count - limit) more characters not shown]"
    }

    // MARK: - Readers

    private static func contentType(of url: URL) -> UTType {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type }
        return UTType(filenameExtension: url.pathExtension) ?? .data
    }

    /// Only the head of a file is ever shown, so only the head is read — a
    /// 400 MB log is a 2 MB read.
    private static func plainText(_ url: URL, declaredText: Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2_000_000) ?? Data()
        if !declaredText, data.prefix(8192).contains(0) {
            throw ReadError(message: "This file isn't text. \(readableSummary)")
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Cut mid-character at the read limit, or not UTF-8 at all: a lossy
        // decode that is nearly clean is the former; otherwise try the rest.
        let lossy = String(decoding: data, as: UTF8.self)
        let damaged = lossy.unicodeScalars.reduce(0) { $0 + ($1 == "\u{FFFD}" ? 1 : 0) }
        if damaged * 50 < max(1, lossy.unicodeScalars.count) { return lossy }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw ReadError(message: "Couldn't decode the text in this file.")
    }

    private static func attributedText(_ url: URL, as type: NSAttributedString.DocumentType) throws -> String {
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        } catch {
            throw ReadError(message: "Couldn't read this document: \(error.localizedDescription)")
        }
    }

    /// The text layer, page by page, stopping once there is more than will
    /// be shown. A scan has no text layer; its first pages are read the way
    /// a screen capture is.
    private static func pdfText(_ url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else { throw ReadError(message: "Couldn't open the PDF.") }
        if document.isLocked { throw ReadError(message: "This PDF is locked with a password.") }
        var text = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let pageText = page.string else { continue }
            text += pageText + "\n\n"
            if text.count > maxCharactersPerFile * 2 { break }
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }

        var read: [String] = []
        for index in 0..<min(document.pageCount, 8) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1600 / max(bounds.width, 1)
            let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let pageText = try await ScreenTextReader.text(in: cgImage)
            if !pageText.isEmpty { read.append(pageText) }
            if read.reduce(0, { $0 + $1.count }) > maxCharactersPerFile { break }
        }
        guard !read.isEmpty else { throw ReadError(message: "No readable text in this PDF.") }
        return read.joined(separator: "\n\n")
    }
}
