import Foundation
import Combine
import AppKit

/// How the app renders regardless of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Forces (or releases) the whole app's appearance — window chrome and the
    /// theme's dynamic colors both follow NSApp.appearance.
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// App-wide preferences, persisted in UserDefaults. Local by default — the
/// cloud notes model is opt-in and needs the user's own key.
final class AppSettings: ObservableObject {
    @Published var cloudNotesEnabled: Bool { didSet { d.set(cloudNotesEnabled, forKey: "cloudNotesEnabled") } }
    @Published var cloudBaseURL: String { didSet { d.set(cloudBaseURL, forKey: "cloudBaseURL") } }
    @Published var cloudAPIKey: String { didSet { Keychain.set(cloudAPIKey, account: Self.apiKeyAccount) } }
    @Published var cloudModel: String { didSet { d.set(cloudModel, forKey: "cloudModel") } }
    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    /// Save each meeting's audio locally (enables "Improve transcript"). On by
    /// default; the files stay next to the meeting JSON, ~15 MB per hour.
    @Published var keepAudio: Bool { didSet { d.set(keepAudio, forKey: "keepAudio") } }
    /// The microphone to record from — a device UID; empty = Automatic
    /// (Seal avoids Bluetooth mics so headphones keep full-quality playback).
    @Published var preferredMicUID: String { didSet { d.set(preferredMicUID, forKey: "preferredMicUID") } }
    /// The chosen device's name, kept so the picker can still show it (as
    /// "not connected") when the device is unplugged.
    @Published var preferredMicName: String { didSet { d.set(preferredMicName, forKey: "preferredMicName") } }
    /// Record what plays on the Mac (the call's other side). On by default;
    /// a change applies from the next recording.
    @Published var captureSystemAudio: Bool { didSet { d.set(captureSystemAudio, forKey: "captureSystemAudio") } }

    @Published var appearance: AppAppearance { didSet { d.set(appearance.rawValue, forKey: "appearance"); appearance.apply() } }
    /// Offer to record when a call app starts using the microphone. On by default.
    @Published var suggestRecording: Bool { didSet { d.set(suggestRecording, forKey: "suggestRecording") } }
    /// Start recording on that signal without asking. Off by default, and
    /// deliberately so: "Seal never records without you saying so" should stay
    /// true unless the user explicitly trades it away here.
    @Published var autoStartOnMeeting: Bool { didSet { d.set(autoStartOnMeeting, forKey: "autoStartOnMeeting") } }
    /// When a recording overlapped a call and every call app has let go of the
    /// microphone, stop on their behalf. On by default.
    @Published var autoStopAfterMeeting: Bool { didSet { d.set(autoStopAfterMeeting, forKey: "autoStopAfterMeeting") } }
    /// Name recordings after the calendar event they overlap and note who was
    /// invited (YAR-36, Pro). Off by default — reading the calendar is opt-in
    /// like every integration, and macOS asks its own permission on top.
    @Published var calendarContextEnabled: Bool { didSet { d.set(calendarContextEnabled, forKey: "calendarContextEnabled") } }

    private let d = UserDefaults.standard
    private static let apiKeyAccount = "cloudAPIKey"

    init() {
        cloudNotesEnabled = d.bool(forKey: "cloudNotesEnabled")
        cloudBaseURL = d.string(forKey: "cloudBaseURL") ?? "https://api.openai.com/v1"
        cloudModel = d.string(forKey: "cloudModel") ?? "gpt-4o-mini"
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        keepAudio = d.object(forKey: "keepAudio") == nil ? true : d.bool(forKey: "keepAudio")
        preferredMicUID = d.string(forKey: "preferredMicUID") ?? ""
        preferredMicName = d.string(forKey: "preferredMicName") ?? ""
        captureSystemAudio = d.object(forKey: "captureSystemAudio") == nil ? true : d.bool(forKey: "captureSystemAudio")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        suggestRecording = d.object(forKey: "suggestRecording") == nil ? true : d.bool(forKey: "suggestRecording")
        autoStartOnMeeting = d.bool(forKey: "autoStartOnMeeting")
        autoStopAfterMeeting = d.object(forKey: "autoStopAfterMeeting") == nil ? true : d.bool(forKey: "autoStopAfterMeeting")
        calendarContextEnabled = d.bool(forKey: "calendarContextEnabled")

        // The API key lives in the macOS Keychain, not UserDefaults. Migrate any
        // legacy plaintext key an earlier build may have stored in UserDefaults.
        if let legacy = d.string(forKey: "cloudAPIKey"), !legacy.isEmpty {
            Keychain.set(legacy, account: Self.apiKeyAccount)
            d.removeObject(forKey: "cloudAPIKey")
        }
        // The Keychain service was renamed com.yarem.LocalScribe → com.yarem.Seal
        // in the 2026 rename; carry an existing key across to the new service, once.
        Keychain.migrateService(account: Self.apiKeyAccount, from: "com.yarem.LocalScribe")
        cloudAPIKey = Keychain.get(account: Self.apiKeyAccount) ?? ""
    }

    /// True only when notes should use the cloud model: opt-in AND a key is
    /// set AND the install is licensed for it. The entitlement check lives
    /// here — not just in Settings — so a beta install whose toggle was
    /// already on falls back to on-device notes rather than silently keeping
    /// a Pro feature. The PrivacyBadge and backend pickers all read this.
    var usingCloudNotes: Bool {
        cloudNotesEnabled
            && !cloudAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
            && (EntitlementService.shared?.allows(.byoCloudKey) ?? false)
    }

    /// The on-device model id, chosen automatically by the machine's RAM — the
    /// user never picks it. Powers notes/titles/chat when not using the cloud.
    var embeddedModelID: String { MLXEngine.defaultModelID }

}
