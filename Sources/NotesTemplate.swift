import Foundation

/// A notes template shapes the sections and focus of the generated meeting
/// notes. The user picks one before generating; each carries the Markdown
/// section headings to produce and a short context hint for the model.
///
/// Note: action items and follow-ups are first-class features with their own
/// sections on the meeting page, so templates deliberately don't repeat them —
/// the notes stay a clean summary, not a duplicate of the checklist below.
struct NotesTemplate: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let sections: [String]
    let guidance: String

    /// Whether this is a user-created template (Pro) rather than a built-in.
    var isCustom: Bool { id.hasPrefix("custom-") }

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

    /// Resolves any template id — built-ins first, then the user's own
    /// (YAR-103). A deleted custom template falls back to General, so a
    /// meeting that remembers one never breaks.
    static func byID(_ id: String?) -> NotesTemplate {
        all.first { $0.id == id }
            ?? CustomTemplateStore.shared.templates.first { $0.id == id }
            ?? general
    }
}

/// The user's own note templates (YAR-103, Seal Pro): the same shape as the
/// built-ins, stored as plain JSON in Application Support next to everything
/// else. Built-ins are never touched — customs only add.
final class CustomTemplateStore: ObservableObject {
    static let shared = CustomTemplateStore()

    @Published private(set) var templates: [NotesTemplate] = []

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    convenience init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Seal", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("templates.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([NotesTemplate].self, from: data) {
            templates = loaded
        }
    }

    /// Creates a new template; the id is minted here so callers never invent
    /// one that could shadow a built-in.
    @discardableResult
    func add(name: String, sections: [String], guidance: String) -> NotesTemplate {
        let template = NotesTemplate(id: "custom-\(UUID().uuidString)",
                                     name: name, sections: sections, guidance: guidance)
        templates.append(template)
        persist()
        return template
    }

    /// Replaces the template with the same id (built-ins can never match —
    /// their ids don't carry the custom prefix).
    func update(_ template: NotesTemplate) {
        guard template.isCustom,
              let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
        persist()
    }

    func remove(id: String) {
        templates.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(templates) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
