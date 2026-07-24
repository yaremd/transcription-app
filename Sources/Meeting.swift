import Foundation

/// One finalized line of a saved transcript.
struct StoredLine: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var speaker: String
    var text: String
    /// When the line was committed (nil for meetings saved before this existed).
    var at: Date? = nil
}

/// One timestamped block of the user's own notes. `at` anchors it to the
/// moment of the conversation it was written in, linking notes to speech.
struct NoteBlock: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String
    var at: Date
}

/// A single action item / task extracted from (or added to) a meeting.
struct ActionItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String
    var done: Bool = false
}

/// A saved meeting: transcript + notes + metadata. Persisted on disk as JSON.
/// Everything about a Meeting lives on the user's Mac — it never leaves it.
struct Meeting: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var date: Date
    var duration: TimeInterval
    var language: String
    var lines: [StoredLine]
    var notes: String
    /// The user's own rough notes jotted during the meeting (optional; nil for
    /// meetings saved before this field existed). Kept as joined plain text —
    /// notes generation and older meetings read this.
    var userNotes: String? = nil
    /// The same notes as timestamped blocks, each anchored to the moment it
    /// was written (nil for meetings saved before this existed).
    var noteBlocks: [NoteBlock]? = nil
    /// The id of the notes template used, if any.
    var templateID: String? = nil
    /// User-assigned tags for organizing meetings.
    var tags: [String]? = nil
    /// Action items / tasks for this meeting.
    var actionItems: [ActionItem]? = nil

    /// The placeholder title for a meeting that hasn't been named yet. The
    /// date/time is shown separately in the UI, so the title's job is to say
    /// what the conversation was about — after Stop, the AI proposes one from
    /// the transcript, and anything still carrying this placeholder is fair
    /// game to rename automatically.
    static let defaultTitle = "New transcription"
}

extension Meeting {
    /// The transcript rendered as "Speaker: text" lines — for copying and notes.
    var transcriptText: String {
        lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    var hasNotes: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A one-line preview of what the meeting was about, for the sidebar: the
    /// first real sentence of the generated notes (its summary) if there is
    /// one, otherwise the first spoken line. This keeps the list scannable even
    /// when a meeting still carries the placeholder title. Empty when there's
    /// nothing to show yet.
    var preview: String {
        if hasNotes {
            for raw in notes.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }   // skip blanks & headings
                var text = line
                while let first = text.first, "-*•>".contains(first) { text.removeFirst() }
                text = text.replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if text.isEmpty || text == "—" { continue }
                return text
            }
        }
        if let first = lines.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return first.text.trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    var openActionItems: [ActionItem] {
        (actionItems ?? []).filter { !$0.done }
    }
}
