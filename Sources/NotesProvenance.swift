import Foundation

/// Which lines of a meeting's notes the model wrote, and which the user did.
///
/// Granola's most-praised detail is one colour: text you typed is ink, text
/// the model wrote is muted, and editing a muted line makes it yours. Seal
/// keeps the model's output verbatim (`Meeting.generatedNotes`) beside the
/// editable notes, so provenance is a line-by-line comparison — no markup in
/// the notes, nothing to migrate, plain text everywhere.
enum NotesProvenance {
    enum Source: Equatable { case human, ai }

    struct Line: Equatable {
        let text: String
        let source: Source
    }

    /// Lines of `notes`, each tagged by whether it still reads exactly as the
    /// model produced it. `generated == nil` means the notes predate
    /// provenance tracking; `fallback` says what to assume then (the model,
    /// when there was a transcript to write from; the user otherwise).
    static func classify(notes: String, generated: String?, fallback: Source) -> [Line] {
        let lines = notes.components(separatedBy: "\n")
        guard let generated else {
            return lines.map { Line(text: $0, source: fallback) }
        }
        let modelLines = Set(generated.components(separatedBy: "\n").map(key).filter { !$0.isEmpty })
        return lines.map { line in
            let k = key(line)
            if k.isEmpty { return Line(text: line, source: .ai) }
            return Line(text: line, source: modelLines.contains(k) ? .ai : .human)
        }
    }

    private static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }
}
