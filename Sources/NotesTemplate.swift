import Foundation

/// A notes template shapes the sections and focus of the generated meeting
/// notes. The user picks one before generating; each carries the Markdown
/// section headings to produce and a short context hint for the model.
///
/// Note: action items and follow-ups are first-class features with their own
/// sections on the meeting page, so templates deliberately don't repeat them —
/// the notes stay a clean summary, not a duplicate of the checklist below.
struct NotesTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let sections: [String]
    let guidance: String

    static let general = NotesTemplate(
        id: "general", name: "General",
        sections: ["Summary", "Key points", "Decisions"],
        guidance: "")

    static let oneOnOne = NotesTemplate(
        id: "one_on_one", name: "1-on-1",
        sections: ["Summary", "Discussion", "Feedback"],
        guidance: "This is a 1-on-1 between a manager and a report. Capture feedback in both directions and any personal or career notes.")

    static let sales = NotesTemplate(
        id: "sales", name: "Sales call",
        sections: ["Summary", "Customer needs", "Objections", "Pricing & terms", "Next steps"],
        guidance: "This is a sales call. Emphasize the customer's pain points, objections, budget and timeline, and concrete next steps.")

    static let interview = NotesTemplate(
        id: "interview", name: "Interview",
        sections: ["Summary", "Candidate background", "Strengths", "Concerns", "Recommendation"],
        guidance: "This is a job interview. Assess the candidate objectively and only from what was actually said.")

    static let standup = NotesTemplate(
        id: "standup", name: "Standup",
        sections: ["Summary", "Updates", "Blockers"],
        guidance: "This is a team standup. Group updates by person where identifiable.")

    static let lecture = NotesTemplate(
        id: "lecture", name: "Lecture",
        sections: ["Summary", "Main topics", "Key takeaways", "Open questions"],
        guidance: "This is a lecture or talk. Produce structured study notes.")

    static let all: [NotesTemplate] = [general, oneOnOne, sales, interview, standup, lecture]

    static func byID(_ id: String?) -> NotesTemplate {
        all.first { $0.id == id } ?? general
    }
}
