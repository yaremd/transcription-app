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
    }
}

private struct VocabularySettings: View {
    @ObservedObject var vocabulary: VocabularyStore
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Vocabulary").font(.title3).bold()
            Text("Names, acronyms, and jargon the transcriber should recognize. Applied on your next recording, and it works in any language — nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Add a term (e.g. a person's name or an acronym)", text: $newTerm)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(trimmedNew.isEmpty)
            }

            if vocabulary.terms.isEmpty {
                Text("No terms yet.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                List {
                    ForEach(vocabulary.terms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                vocabulary.remove(term)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 160)
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
