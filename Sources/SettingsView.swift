import SwiftUI

/// The app's Settings window (⌘,), with a tab per preference group.
struct SettingsView: View {
    @ObservedObject var vocabulary: VocabularyStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var entitlements: EntitlementService

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
            LicenseSettings(entitlements: entitlements)
                .tabItem { Label("License", systemImage: "checkmark.seal") }
        }
        .frame(width: 540, height: 460)
        .tint(Theme.accent)
        .environmentObject(entitlements)
    }
}

/// Settings → License: the quiet, factual view of this install's state.
/// The selling happens in the UpgradeSheet; this pane manages what you own.
private struct LicenseSettings: View {
    @ObservedObject var entitlements: EntitlementService
    @State private var showUpgrade = false
    @State private var deactivating = false
    @State private var deactivateError: String?

    private let client: LicenseActivating = PolarLicenseClient()

    var body: some View {
        Form {
            Section("This Mac") {
                statusRow
                if case .trial = entitlements.entitlement {
                    trialFooter
                }
            }

            switch entitlements.entitlement {
            case .free, .trial:
                Section {
                    Button("See what's in Seal Pro…") { showUpgrade = true }
                    Text("Everything you use today stays free — unlimited meetings, full-accuracy transcription, notes, search, and export. A Pro license is yours forever: no account, no subscription, checked once at activation. Seal never phones home.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .pro, .lifetime:
                Section("License") {
                    if let license = entitlements.license {
                        LabeledContent("Key", value: maskedKey(license.key))
                    }
                    Button(deactivating ? "Deactivating…" : "Deactivate on this Mac") { deactivate() }
                        .disabled(deactivating)
                    if let deactivateError {
                        Text(deactivateError)
                            .font(.caption)
                            .foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("A license covers two Macs. Deactivating frees this one so you can activate elsewhere — your meetings and notes stay right here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { entitlements.refresh() }
        .sheet(isPresented: $showUpgrade) {
            UpgradeSheet().environmentObject(entitlements)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch entitlements.entitlement {
        case .free:
            LabeledContent("Plan", value: "Seal Free")
        case .trial:
            LabeledContent("Plan", value: "Seal Pro — trial")
        case .pro(let updatesThrough):
            LabeledContent("Plan", value: "Seal Pro")
            LabeledContent("Updates included through",
                           value: updatesThrough.formatted(date: .abbreviated, time: .omitted))
            Text("After that, Seal keeps working exactly as it is; a \(Pricing.renewal)/yr renewal is only for newer updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .lifetime:
            LabeledContent("Plan", value: "Seal Pro — lifetime updates")
        }
    }

    @ViewBuilder
    private var trialFooter: some View {
        if let days = entitlements.trialDaysLeft {
            Text("\(days) day\(days == 1 ? "" : "s") left. When the trial ends, Pro features pause — every meeting, note, and export stays yours.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return key }
        return "…" + key.suffix(8)
    }

    private func deactivate() {
        guard let license = entitlements.license else { return }
        deactivating = true
        deactivateError = nil
        Task { @MainActor in
            defer { deactivating = false }
            do {
                try await client.deactivate(license)
                entitlements.clearLicense()
            } catch {
                // Keep the license: dropping it locally while Polar still
                // counts the seat would strand one of the two activations.
                deactivateError = (error as? LicenseError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
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

            Section("Meetings") {
                Toggle("Offer to record when a meeting starts", isOn: $settings.suggestRecording)
                Text("When a call app — Zoom, Teams, or a Meet tab in your browser — starts using the microphone, Seal shows a small prompt. Watching for this needs no extra permission, and nothing records without your click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Start recording automatically", isOn: $settings.autoStartOnMeeting)
                Text("Skip the prompt and start on your behalf when a meeting begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Stop when the meeting ends", isOn: $settings.autoStopAfterMeeting)
                Text("When every call app has let go of the microphone, Seal stops the recording and offers your notes. Recordings made outside a call are never touched.")
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
