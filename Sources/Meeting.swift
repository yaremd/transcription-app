import Foundation

/// One finalized line of a saved transcript.
struct StoredLine: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var speaker: String
    var text: String
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
    /// meetings saved before this field existed).
    var userNotes: String? = nil
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

    var openActionItems: [ActionItem] {
        (actionItems ?? []).filter { !$0.done }
    }
}
