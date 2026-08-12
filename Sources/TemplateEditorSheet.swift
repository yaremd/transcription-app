import SwiftUI

/// Create, edit, and delete the user's own note templates (YAR-103, Pro).
/// Left: the list — built-ins shown read-only for reference, customs
/// editable. Right: the editor for the selected custom template. Deliberately
/// small: a template is a name, section headings, and one guidance line.
struct TemplateEditorSheet: View {
    @ObservedObject private var store = CustomTemplateStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String?
    @State private var name = ""
    @State private var sectionsText = ""
    @State private var guidance = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Note templates")
                    .font(Theme.title)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            ThemeDivider()

            HStack(spacing: 0) {
                list
                    .frame(width: 200)
                ThemeDivider().frame(width: 1).frame(maxHeight: .infinity)
                editor
            }
        }
        .frame(width: 620, height: 440)
        .background(Theme.background)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Built-in")
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                ForEach(NotesTemplate.all) { template in
                    Text(template.name)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                SectionLabel("Yours")
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                ForEach(store.templates) { template in
                    Button {
                        select(template)
                    } label: {
                        HStack {
                            Text(template.name.isEmpty ? "Untitled" : template.name)
                                .font(Theme.body)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(selectedID == template.id ? Theme.hover : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    let created = store.add(name: "", sections: ["Summary"], guidance: "")
                    select(created)
                } label: {
                    Label("New template", systemImage: "plus")
                        .font(Theme.body)
                }
                .buttonStyle(.linearQuietCompact)
                .padding(12)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.sidebar)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if selectedID == nil {
            VStack(spacing: 8) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select one of your templates, or make a new one.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                Text("A template shapes the sections and focus of generated notes — the transcript itself is never changed by it.")
                    .font(Theme.sub)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Name")
                TextField("Client kickoff, Supervision session…", text: $name)
                    .linearField()
                    .onChange(of: name) { _, _ in save() }

                SectionLabel("Sections — one per line")
                TextEditor(text: $sectionsText)
                    .font(Theme.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 120)
                    .insetPanel(radius: 6)
                    .onChange(of: sectionsText) { _, _ in save() }

                SectionLabel("Guidance for the AI (optional)")
                TextEditor(text: $guidance)
                    .font(Theme.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 70)
                    .insetPanel(radius: 6)
                    .onChange(of: guidance) { _, _ in save() }

                Spacer()
                HStack {
                    Button("Delete template") {
                        if let selectedID { store.remove(id: selectedID) }
                        selectedID = nil
                    }
                    .buttonStyle(.linearDestructiveCompact)
                    Spacer()
                    Text("Saved automatically")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(18)
        }
    }

    private func select(_ template: NotesTemplate) {
        selectedID = template.id
        name = template.name
        sectionsText = template.sections.joined(separator: "\n")
        guidance = template.guidance
    }

    private func save() {
        guard let selectedID else { return }
        let sections = sectionsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.update(NotesTemplate(id: selectedID,
                                   name: name.trimmingCharacters(in: .whitespaces),
                                   sections: sections.isEmpty ? ["Summary"] : sections,
                                   guidance: guidance.trimmingCharacters(in: .whitespaces)))
    }
}
