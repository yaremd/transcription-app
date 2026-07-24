import SwiftUI

/// The app's Settings window (⌘,), with a tab per preference group.
struct SettingsView: View {
    @ObservedObject var vocabulary: VocabularyStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotesSettings(settings: settings)
                .tabItem { Label("Notes", systemImage: "brain") }
            VocabularySettings(vocabulary: vocabulary)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            RecordingSettings(settings: settings)
                .tabItem { Label("Recording", systemImage: "waveform") }
        }
        .frame(width: 540, height: 460)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Offer to record when a meeting starts", isOn: $settings.suggestRecording)
                Text("When Zoom, Teams, or Webex comes to the front and you're not already recording, Seal shows a small prompt. Nothing records without your click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VocabularySettings: View {
    @ObservedObject var vocabulary: VocabularyStore
    @State private var newTerm = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Name, acronym, or jargon", text: $newTerm)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(trimmedNew.isEmpty)
                }
                Text("Terms the transcriber should recognize — applied on your next recording, in any language. Nothing leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Terms") {
                if vocabulary.terms.isEmpty {
                    Text("No terms yet — try the names of people you meet with.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vocabulary.terms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                vocabulary.remove(term)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \"\(term)\"")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
    @State private var models: [OllamaModel] = []
    @State private var loadFailed = false

    private let titleModelHint = "ollama pull llama3.2:3b"

    var body: some View {
        Form {
            Section("Notes model (on your Mac)") {
                if !models.isEmpty {
                    Picker("Model", selection: $settings.notesModel) {
                        ForEach(models) { model in
                            Text("\(model.name)  ·  \(model.sizeLabel)").tag(model.name)
                        }
                        // Keep a stored-but-uninstalled choice visible rather than blanking the picker.
                        if !settings.notesModel.isEmpty,
                           !models.contains(where: { $0.name == settings.notesModel }) {
                            Text("\(settings.notesModel)  ·  not installed").tag(settings.notesModel)
                        }
                    }
                    Text("Bigger models write better notes but run slower. Titles and speaker names automatically use your smallest model, so naming stays fast.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if loadFailed {
                    Text("Couldn't reach Ollama at localhost:11434. Start Ollama to choose a model — until then, notes use \(AppSettings.defaultNotesModel).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Looking for installed models…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text("Want instant titles? Install a small model:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(titleModelHint)
                        .font(.system(.caption, design: .monospaced))
                    Button { copyToPasteboard(titleModelHint) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            .disabled(settings.cloudNotesEnabled)

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
        .task {
            let list = await OllamaModels.installed()
            models = list
            loadFailed = list.isEmpty
            settings.resolveModels(list)
        }
    }
}

private struct RecordingSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Keep meeting audio", isOn: $settings.keepAudio)
                Text("Saves each meeting's audio on your Mac, next to its transcript (~15 MB per hour). This powers \"Improve transcript\" — re-transcribing a finished meeting with the accurate model. Nothing ever leaves your Mac; deleting a meeting deletes its audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
