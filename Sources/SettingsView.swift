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
                Text("Names Seal should spell correctly. When it hears one nearly right — \"Demitra\" for \"Dmytro\" — it fixes the spelling as the transcript is written. Nothing leaves your Mac.")
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
    @ObservedObject private var modelStatus = EmbeddedModelStatus.shared

    var body: some View {
        Form {
            Section("Notes model (on your Mac)") {
                modelStatusView
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
        .task { await modelStatus.attach() }
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch modelStatus.phase {
        case .unsupported:
            Label("On-device notes need an Apple-silicon Mac. Turn on a cloud model below to use notes here.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            Label("On-device model ready — notes, titles, and chat run privately on your Mac.", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading the on-device model… \(Int(progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: progress)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Download failed: \(message)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { modelStatus.downloadNow() }
            }
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes, titles, and chat run on a private AI model on your Mac — about 2–4 GB depending on your Mac's memory, downloaded once. It downloads automatically the first time you need notes, or get it now.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Download now") { modelStatus.downloadNow() }
            }
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
