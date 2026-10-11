import SwiftUI

/// The meeting's notes as a document: the model's write-up at document size
/// on the page's measure, with the user's own lines in ink and the model's in
/// muted ink (see `NotesProvenance`). Markdown headings and bullets render,
/// inline bold and italics render; nothing else is interpreted.
struct NotesDocument: View {
    let notes: String
    let generated: String?
    /// What to assume for notes that predate provenance tracking.
    var fallback: NotesProvenance.Source = .ai

    var body: some View {
        let lines = NotesProvenance.classify(notes: notes, generated: generated, fallback: fallback)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ink(_ source: NotesProvenance.Source) -> Color {
        source == .human ? .primary : Theme.inkAI
    }

    @ViewBuilder
    private func lineView(_ line: NotesProvenance.Line) -> some View {
        let raw = line.text
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let color = ink(line.source)
        if trimmed.hasPrefix("### ") {
            Text(clean(String(trimmed.dropFirst(4))))
                .font(Theme.docBodyMedium)
                .foregroundStyle(color)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("## ") {
            // Section headings ("Summary", "Key points") carry the page's
            // structure — they need air above to read as landmarks.
            Text(clean(String(trimmed.dropFirst(3))))
                .font(Theme.docHeading)
                .foregroundStyle(color)
                .padding(.top, 14)
        } else if trimmed.hasPrefix("# ") {
            Text(clean(String(trimmed.dropFirst(2))))
                .font(Theme.docHeading)
                .foregroundStyle(color)
                .padding(.top, 14)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.tertiary)
                inlineText(String(trimmed.dropFirst(2)))
                    .foregroundStyle(color)
                    .lineSpacing(Theme.docLineSpacing)
            }
            .font(Theme.docBody)
            .padding(.leading, indent(raw))
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 6)
        } else {
            inlineText(trimmed)
                .font(Theme.docBody)
                .foregroundStyle(color)
                .lineSpacing(Theme.docLineSpacing)
        }
    }

    /// Nested bullets keep their nesting: two leading spaces per level.
    private func indent(_ raw: String) -> CGFloat {
        let spaces = raw.prefix { $0 == " " }.count
        return CGFloat(spaces / 2) * 16
    }

    /// Inline markdown (bold, italics) rendered properly instead of being
    /// stripped — the model uses **bold** for names and decisions, and that
    /// emphasis is worth keeping.
    private func inlineText(_ s: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(clean(s))
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
    }
}

/// The user's own timestamped notes — typed during the meeting, or added on
/// its page afterwards — as document lines: a time that jumps the transcript
/// to that moment, the note's formatting marks, and the text in ink. The
/// draft field at the end is always there, so a page is never read-only.
struct JotList: View {
    @Binding var blocks: [NoteBlock]
    let onJump: (Date) -> Void
    let onAdd: (String) -> Void
    let onDelete: (UUID) -> Void
    var placeholder = "Add a note — Return saves it"
    /// Bumped to put the cursor in the draft field (a recording just started).
    var focusPulse = 0

    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($blocks) { $block in
                EditableNoteRow(block: $block,
                                onJump: onJump,
                                onDelete: { onDelete(block.id) })
                    .id(block.id)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.docBody)
                    .focused($draftFocused)
                    .onSubmit {
                        let text = draft
                        draft = ""
                        onAdd(text)
                        draftFocused = true
                    }
                    .help("Times link to the talk — click a note's time to see that moment. Start a note with \"- \" for a bullet or \"[]\" for a task.")
            }
        }
        .onChange(of: focusPulse) { _, _ in draftFocused = true }
    }
}
