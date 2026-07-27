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

    @Published var appearance: AppAppearance { didSet { d.set(appearance.rawValue, forKey: "appearance"); appearance.apply() } }
    /// Offer to record when a call app comes to the front. On by default.
    @Published var suggestRecording: Bool { didSet { d.set(suggestRecording, forKey: "suggestRecording") } }

    private let d = UserDefaults.standard
    private static let apiKeyAccount = "cloudAPIKey"

    init() {
        cloudNotesEnabled = d.bool(forKey: "cloudNotesEnabled")
        cloudBaseURL = d.string(forKey: "cloudBaseURL") ?? "https://api.openai.com/v1"
        cloudModel = d.string(forKey: "cloudModel") ?? "gpt-4o-mini"
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        keepAudio = d.object(forKey: "keepAudio") == nil ? true : d.bool(forKey: "keepAudio")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        suggestRecording = d.object(forKey: "suggestRecording") == nil ? true : d.bool(forKey: "suggestRecording")

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

    /// True only when notes should use the cloud model: opt-in AND a key is set.
    var usingCloudNotes: Bool {
        cloudNotesEnabled && !cloudAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The on-device model id, chosen automatically by the machine's RAM — the
    /// user never picks it. Powers notes/titles/chat when not using the cloud.
    var embeddedModelID: String { MLXEngine.defaultModelID }

}
