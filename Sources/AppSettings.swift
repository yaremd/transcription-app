import Foundation
import Combine

/// App-wide preferences, persisted in UserDefaults. Currently the opt-in cloud
/// model for notes. Off by default — the app is fully local unless the user
/// deliberately turns this on and supplies their own key.
final class AppSettings: ObservableObject {
    @Published var cloudNotesEnabled: Bool { didSet { d.set(cloudNotesEnabled, forKey: "cloudNotesEnabled") } }
    @Published var cloudBaseURL: String { didSet { d.set(cloudBaseURL, forKey: "cloudBaseURL") } }
    @Published var cloudAPIKey: String { didSet { Keychain.set(cloudAPIKey, account: Self.apiKeyAccount) } }
    @Published var cloudModel: String { didSet { d.set(cloudModel, forKey: "cloudModel") } }
    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    /// Save each meeting's audio locally (enables "Improve transcript"). On by
    /// default; the files stay next to the meeting JSON, ~15 MB per hour.
    @Published var keepAudio: Bool { didSet { d.set(keepAudio, forKey: "keepAudio") } }

    private let d = UserDefaults.standard
    private static let apiKeyAccount = "cloudAPIKey"

    init() {
        cloudNotesEnabled = d.bool(forKey: "cloudNotesEnabled")
        cloudBaseURL = d.string(forKey: "cloudBaseURL") ?? "https://api.openai.com/v1"
        cloudModel = d.string(forKey: "cloudModel") ?? "gpt-4o-mini"
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        keepAudio = d.object(forKey: "keepAudio") == nil ? true : d.bool(forKey: "keepAudio")

        // The API key lives in the macOS Keychain, not UserDefaults. Migrate any
        // legacy plaintext key an earlier build may have stored in UserDefaults.
        if let legacy = d.string(forKey: "cloudAPIKey"), !legacy.isEmpty {
            Keychain.set(legacy, account: Self.apiKeyAccount)
            d.removeObject(forKey: "cloudAPIKey")
        }
        cloudAPIKey = Keychain.get(account: Self.apiKeyAccount) ?? ""
    }

    /// True only when notes should use the cloud model: opt-in AND a key is set.
    var usingCloudNotes: Bool {
        cloudNotesEnabled && !cloudAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
