import Foundation

/// What a question about a meeting is asked against: the transcript lines the
/// model has already been handed, so each new question carries only what was
/// said since — not the whole meeting again. On an hour-long call that is the
/// difference between an answer in a couple of seconds and one in twenty.
///
/// Lines are keyed by id rather than position because a live transcript does
/// not only grow at its end: a long utterance routinely finishes decoding
/// after a shorter, later one and is then inserted where it was spoken. A fed
/// line may also keep growing while its speaker is still talking — that
/// growth is new text. A fed line that changed any other way (an edit, a
/// re-transcription, a pulled echo) means the model's memory no longer
/// matches the meeting, and the only honest move is to start over.
struct AskTranscriptFeed: Equatable {
    /// One transcript line as the model should read it.
    struct Line: Equatable {
        let id: UUID
        /// "[12:04] Dmytro" — when (if known) and who.
        let label: String
        let text: String

        var rendered: String { "\(label): \(text)" }
    }

    enum Step: Equatable {
        /// Nothing new since the last question.
        case nothing
        /// What was said since the last question, ready to go before it.
        case append(String)
        /// The lines already read changed underneath the model: everything,
        /// from the top, in a fresh conversation.
        case restart(String)
    }

    private(set) var fed: [UUID: String] = [:]

    var isEmpty: Bool { fed.isEmpty }

    /// Records `lines` as read and says what the next question must carry.
    mutating func update(with lines: [Line]) -> Step {
        let current = Dictionary(lines.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        for (id, old) in fed {
            guard let now = current[id], now == old || now.hasPrefix(old) else {
                return restart(with: lines)
            }
        }
        if fed.isEmpty { return restart(with: lines) }

        var additions: [String] = []
        for line in lines {
            if let old = fed[line.id] {
                if line.text != old {
                    let grown = line.text.dropFirst(old.count).trimmingCharacters(in: .whitespaces)
                    if !grown.isEmpty { additions.append("\(line.label) (continued): \(grown)") }
                }
            } else {
                additions.append(line.rendered)
            }
            fed[line.id] = line.text
        }
        return additions.isEmpty ? .nothing : .append(additions.joined(separator: "\n"))
    }

    private mutating func restart(with lines: [Line]) -> Step {
        fed = Dictionary(lines.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        return .restart(lines.map(\.rendered).joined(separator: "\n"))
    }

    /// "[12:04]" for a moment `offset` seconds into the meeting.
    static func stamp(_ offset: TimeInterval) -> String {
        let total = max(0, Int(offset))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "[%d:%02d:%02d]", h, m, s) : String(format: "[%02d:%02d]", m, s)
    }
}
