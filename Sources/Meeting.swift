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

    /// The default title for a new meeting, derived from its start time.
    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
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
