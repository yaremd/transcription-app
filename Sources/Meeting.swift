import Foundation

/// One finalized line of a saved transcript.
struct StoredLine: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var speaker: String
    var text: String
    /// When the line was committed (nil for meetings saved before this existed).
    var at: Date? = nil
    /// Where this speech sits in its stream's saved audio, in seconds — the
    /// recording's own timeline, unmoved by pauses. What speaker labels are
    /// matched against. nil for meetings saved before this existed.
    var start: TimeInterval? = nil
    var end: TimeInterval? = nil
    /// Which far-side voice said this ("S1", "S2", …), once the meeting's
    /// audio has been through speaker identification. nil until then, and
    /// always nil for "You" — the mic needs no telling apart.
    var voice: String? = nil
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
    /// The sidebar folder this meeting is filed under (a project, a client).
    /// nil = unfiled — the meeting lives in the date-grouped library instead.
    var folder: String? = nil
    /// Action items / tasks for this meeting.
    var actionItems: [ActionItem]? = nil
    /// Real participant names, keyed by the raw speaker label ("You"/"Others").
    /// nil = never asked; empty = the user was asked and declined (so the
    /// suggestion isn't offered again); entries rename how speakers display.
    var speakerNames: [String: String]? = nil
    /// The calendar event this recording belonged to, when calendar context
    /// was on (YAR-36): its title, and who was invited. nil = no event, or
    /// the feature was off.
    var calendarTitle: String? = nil
    var calendarAttendees: [String]? = nil

    /// The placeholder title for a meeting that hasn't been named yet. The
    /// date/time is shown separately in the UI, so the title's job is to say
    /// what the conversation was about — after Stop, the AI proposes one from
    /// the transcript, and anything still carrying this placeholder is fair
    /// game to rename automatically.
    static let defaultTitle = "New transcription"
}

extension Meeting {
    /// The transcript rendered as "Speaker: text" lines — for copying and
    /// export. Far-side lines carry their identified voice when one is known.
    var transcriptText: String {
        lines.map { "\(displayLabel(for: $0)): \($0.text)" }.joined(separator: "\n")
    }

    /// How a raw speaker label ("You"/"Others") should display — the confirmed
    /// real name when one is known, the label itself otherwise.
    func displayName(for speaker: String) -> String {
        if let mapped = speakerNames?[speaker],
           !mapped.trimmingCharacters(in: .whitespaces).isEmpty {
            return mapped
        }
        return speaker
    }

    /// What one line's speaker is called on screen. A far-side line with an
    /// identified voice shows that voice — the user's name for it if given,
    /// "Speaker 2" otherwise; everything else falls back to the raw label.
    func displayLabel(for line: StoredLine) -> String {
        guard let voice = line.voice else { return displayName(for: line.speaker) }
        if let named = speakerNames?[voice],
           !named.trimmingCharacters(in: .whitespaces).isEmpty {
            return named
        }
        if voice.first == "S", let number = Int(voice.dropFirst()) {
            return "Speaker \(number)"
        }
        return voice
    }

    /// The identified far-side voices this transcript uses, in order.
    var identifiedVoices: [String] { SpeakerLabeler.voices(in: lines) }

    /// Transcript text for AI prompts: You/Others keep their baked-in
    /// semantics, far-side lines are labeled by voice (S1, S2, …) when it is
    /// known, and a participants header maps every label to a real name the
    /// user (or the name suggester) has provided.
    var aiTranscript: String {
        let body = lines
            .map { "\($0.voice ?? $0.speaker): \($0.text)" }
            .joined(separator: "\n")
        var header: [String] = []
        if let names = speakerNames, !names.isEmpty {
            let parts = names
                .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "\($0.key) = \($0.value)" }
                .sorted()
            if !parts.isEmpty { header.append("PARTICIPANTS: " + parts.joined(separator: "; ")) }
        }
        // Who the calendar says was invited — context for notes and the
        // speaker-name suggester, clearly labeled as the invite list rather
        // than who actually spoke.
        if let attendees = calendarAttendees, !attendees.isEmpty {
            header.append("INVITED (from calendar): " + attendees.joined(separator: ", "))
        }
        guard !header.isEmpty else { return body }
        return header.joined(separator: "\n") + "\n\n" + body
    }

    /// The title a session should persist with: a name the user (or a past
    /// save) already gave wins; then the calendar event's name; then the
    /// placeholder — which the AI titler later replaces, and it skips
    /// anything that no longer carries the placeholder.
    static func startingTitle(existing: String?, calendar: String?) -> String {
        if let existing {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != defaultTitle { return existing }
        }
        if let calendar {
            let trimmed = calendar.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return defaultTitle
    }

    var hasNotes: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The title to show in lists (sidebar, the action-items inbox): the real
    /// title, or — when the meeting is still unnamed — its content preview, so a
    /// group is never an ambiguous "New transcription" among many identical ones.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != Meeting.defaultTitle { return title }
        let p = preview
        if !p.isEmpty { return p }
        return trimmed.isEmpty ? Meeting.defaultTitle : title
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
