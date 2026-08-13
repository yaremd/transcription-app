import SwiftUI

/// The app's Settings window (⌘,), with a tab per preference group.
struct SettingsView: View {
    @ObservedObject var vocabulary: VocabularyStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var entitlements: EntitlementService
    @ObservedObject var monitor: AudioMonitor

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotesSettings(settings: settings)
                .tabItem { Label("Notes", systemImage: "brain") }
            VocabularySettings(vocabulary: vocabulary)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            RecordingSettings(settings: settings, monitor: monitor)
                .tabItem { Label("Recording", systemImage: "waveform") }
            LicenseSettings(entitlements: entitlements)
                .tabItem { Label("License", systemImage: "checkmark.seal") }
        }
        .frame(width: 540, height: 460)
        // `selection`, not `accent`: Settings is mostly toggles and pickers,
        // which macOS fills with the tint and draws a white knob on.
        .tint(Theme.selection)
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

    private let client: LicenseActivating = FreemiusLicenseClient()

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
#if DEBUG
            Section("QA (debug builds only)") {
                Picker("Force state", selection: debugStateBinding) {
                    ForEach(DebugEntitlementState.allCases) { state in
                        Text(state.label).tag(state)
                    }
                }
                Text("Walks the entitlement matrix (YAR-102) on one machine: every gated surface can be checked in every state. Ephemeral — never saved, gone on relaunch, absent from release builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
#endif
        }
        .formStyle(.grouped)
        .onAppear { entitlements.refresh() }
        .sheet(isPresented: $showUpgrade) {
            UpgradeSheet().environmentObject(entitlements)
        }
    }

#if DEBUG
    private var debugStateBinding: Binding<DebugEntitlementState> {
        Binding(
            get: { DebugEntitlementState.matching(entitlements.debugForcedEntitlement) },
            set: { entitlements.debugForcedEntitlement = $0.entitlement })
    }
#endif

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
                // Keep the license: dropping it locally while Freemius still
                // counts the seat would strand one of the two activations.
                deactivateError = (error as? LicenseError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

#if DEBUG
/// The QA matrix's manual half (YAR-102): states the License pane can force
/// in debug builds so every gated surface can be eyeballed on one machine.
private enum DebugEntitlementState: String, CaseIterable, Identifiable {
    case off, free, trial, proInWindow, proLapsed, lifetime
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off (real state)"
        case .free: return "Free"
        case .trial: return "Trial — 3 days left"
        case .proInWindow: return "Pro — updates current"
        case .proLapsed: return "Pro — updates lapsed"
        case .lifetime: return "Lifetime"
        }
    }

    var entitlement: Entitlement? {
        switch self {
        case .off: return nil
        case .free: return .free
        case .trial: return .trial(expires: Date().addingTimeInterval(3 * 86_400))
        case .proInWindow: return .pro(updatesThrough: Date().addingTimeInterval(300 * 86_400))
        case .proLapsed: return .pro(updatesThrough: Date().addingTimeInterval(-30 * 86_400))
        case .lifetime: return .lifetime
        }
    }

    static func matching(_ entitlement: Entitlement?) -> DebugEntitlementState {
        switch entitlement {
        case nil: return .off
        case .free: return .free
        case .trial: return .trial
        case .pro(let through): return through > Date() ? .proInWindow : .proLapsed
        case .lifetime: return .lifetime
        }
    }
}
#endif

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var entitlements: EntitlementService
    @State private var showUpgrade = false
    @State private var calendarDenied = false

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

            Section("Calendar") {
                if entitlements.allows(.calendarContext) {
                    Toggle("Name recordings after their calendar event", isOn: $settings.calendarContextEnabled)
                        .onChange(of: settings.calendarContextEnabled) { _, enabled in
                            guard enabled else { calendarDenied = false; return }
                            Task { @MainActor in
                                let granted = await CalendarContext.requestAccess()
                                calendarDenied = !granted
                                if !granted { settings.calendarContextEnabled = false }
                            }
                        }
                    if calendarDenied {
                        Text("Calendar access was declined. Grant it in System Settings → Privacy & Security → Calendars, then turn this on again.")
                            .font(.caption)
                            .foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("When a recording starts during a calendar event, Seal names the meeting after it and notes who was invited — context the notes and speaker suggestions can use. Read-only, on your Mac; nothing leaves it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // The Settings window can't reach the main window's
                    // sheet, so the locked row presents its own (the
                    // cloud-notes pattern).
                    HStack {
                        Text("Name recordings after their calendar event")
                        ProBadge()
                        Spacer()
                        Button("See Seal Pro…") { showUpgrade = true }
                    }
                    Text("Calendar context is part of Seal Pro. Your calendar is only ever read on your Mac, and only when a recording starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showUpgrade) {
            UpgradeSheet(highlighted: .calendarContext).environmentObject(entitlements)
        }
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
    @EnvironmentObject private var entitlements: EntitlementService
    @ObservedObject private var modelStatus = EmbeddedModelStatus.shared
    @State private var showUpgrade = false

    var body: some View {
        Form {
            Section("Notes model (on your Mac)") {
                modelStatusView
            }
            .disabled(settings.usingCloudNotes)

            Section {
                if entitlements.allows(.byoCloudKey) {
                    Toggle("Use a cloud model for notes", isOn: $settings.cloudNotesEnabled)
                    Text("Off by default. When on, only the transcript text (never your audio) is sent to the model you configure, using your own API key. Transcription always stays on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // The Settings window can't reach the main window's sheet,
                    // so the locked row presents its own.
                    HStack {
                        Text("Use a cloud model for notes")
                        ProBadge()
                        Spacer()
                        Button("See Seal Pro…") { showUpgrade = true }
                    }
                    Text("Optional frontier-model notes with your own API key are part of Seal Pro. On-device notes stay free, and transcription always stays on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if settings.cloudNotesEnabled && entitlements.allows(.byoCloudKey) {
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
        .sheet(isPresented: $showUpgrade) {
            UpgradeSheet(highlighted: .byoCloudKey).environmentObject(entitlements)
        }
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
    @ObservedObject var monitor: AudioMonitor
    @StateObject private var inputs = AudioInputsObserver()

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Record from", selection: micSelection) {
                    Text("Automatic (recommended)").tag("")
                    ForEach(inputs.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                    if isChosenMissing {
                        Text("\(settings.preferredMicName) — not connected").tag(settings.preferredMicUID)
                    }
                }
                if isChosenMissing {
                    Text("That microphone isn't connected, so the automatic choice is used until it returns.")
                        .font(.caption)
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Automatic picks a wired microphone when your headset is Bluetooth, so your headphones keep full-quality playback. A change applies immediately, even mid-recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Call audio") {
                Toggle("Record the call's other side (system audio)", isOn: $settings.captureSystemAudio)
                Text("Captures what plays on your Mac — the other participants of a call — as the \"Others\" side of the transcript. Turning it off records only your microphone. Applies from the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    private var isChosenMissing: Bool {
        !settings.preferredMicUID.isEmpty
            && !inputs.devices.contains { $0.id == settings.preferredMicUID }
    }

    /// Selecting stores the preference and applies it to a live session.
    private var micSelection: Binding<String> {
        Binding(
            get: { settings.preferredMicUID },
            set: { uid in
                settings.preferredMicUID = uid
                if let name = inputs.devices.first(where: { $0.id == uid })?.name {
                    settings.preferredMicName = name
                }
                monitor.applyMicrophoneSelection()
            })
    }
}
