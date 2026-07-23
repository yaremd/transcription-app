import SwiftUI

/// The app's Settings window (⌘,), with a tab per preference group.
struct SettingsView: View {
    @ObservedObject var vocabulary: VocabularyStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            VocabularySettings(vocabulary: vocabulary)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            NotesSettings(settings: settings)
                .tabItem { Label("Notes", systemImage: "brain") }
        }
        .frame(width: 520, height: 440)
        .tint(Theme.accent)
    }
}

private struct VocabularySettings: View {
    @ObservedObject var vocabulary: VocabularyStore
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Vocabulary").font(Theme.title)
            Text("Names, acronyms, and jargon the transcriber should recognize. Applied on your next recording, and it works in any language — nothing leaves your Mac.")
                .font(Theme.sub)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Add a term (e.g. a person's name or an acronym)", text: $newTerm)
                    .linearField()
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.linearQuietCompact)
                    .disabled(trimmedNew.isEmpty)
            }

            if vocabulary.terms.isEmpty {
                Text("No terms yet.")
                    .font(Theme.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(vocabulary.terms.enumerated()), id: \.element) { index, term in
                            if index > 0 { ThemeDivider() }
                            HStack {
                                Text(term).font(Theme.body)
                                Spacer()
                                Button {
                                    vocabulary.remove(term)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(minHeight: 160)
                .insetPanel(radius: 6)
            }
        }
        .padding(20)
    }

    private var trimmedNew: String {
        newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        vocabulary.add(newTerm)
        newTerm = ""
    }
}

private struct NotesSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Use a cloud model for notes", isOn: $settings.cloudNotesEnabled)
                Text("Off by default. When on, only the transcript text (never your audio) is sent to the model you configure, using your own API key. Transcription always stays on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.cloudNotesEnabled {
                Section("OpenAI-compatible endpoint") {
                    TextField("Base URL", text: $settings.cloudBaseURL)
                    SecureField("API key", text: $settings.cloudAPIKey)
                    TextField("Model", text: $settings.cloudModel)
                }
                Section {
                    Text("Works with OpenAI, OpenRouter, Groq, LM Studio, and similar. Your key is stored on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
