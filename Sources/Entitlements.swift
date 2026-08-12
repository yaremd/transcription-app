import Foundation
import Combine
import CryptoKit

// MARK: - The paywall line

/// Every feature behind the Seal Pro license — the single place the free/Pro
/// line is defined. Free is not listed here because free is everything else,
/// permanently: capture, live transcription at full accuracy, standard notes
/// and built-in templates, the meeting library, full-text search, and
/// Markdown/PDF export are never gated, in any state, including an expired
/// trial. History access and raw export must never appear in this enum.
enum ProFeature: String, CaseIterable, Identifiable {
    case speakerSplit
    case askMeeting
    case reshapeSummary
    case followUpDraft
    case actionTracking
    case polishPass
    case customTemplates
    case advancedExport
    case calendarContext
    case byoCloudKey
    case semanticMemory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speakerSplit: return "Speaker split"
        case .askMeeting: return "Ask the meeting"
        case .reshapeSummary: return "Reshape summary"
        case .followUpDraft: return "Follow-up drafts"
        case .actionTracking: return "Action-item tracking"
        case .polishPass: return "Improve transcript"
        case .customTemplates: return "Custom templates"
        case .advancedExport: return "Advanced export"
        case .calendarContext: return "Calendar context"
        case .byoCloudKey: return "Cloud notes (your key)"
        case .semanticMemory: return "Meeting memory"
        }
    }

    /// One line for the upgrade sheet's feature grid.
    var blurb: String {
        switch self {
        case .speakerSplit: return "Who said what — every voice named"
        case .askMeeting: return "Answers from the transcript, on demand"
        case .reshapeSummary: return "Regenerate notes in a different shape"
        case .followUpDraft: return "A ready-to-send follow-up, drafted locally"
        case .actionTracking: return "Action items tracked across meetings"
        case .polishPass: return "Re-transcribe at maximum accuracy"
        case .customTemplates: return "Notes in your format (built-ins stay free)"
        case .advancedExport: return "Word, subtitles, Obsidian / Notion"
        case .calendarContext: return "Titles and attendees from your calendar"
        case .byoCloudKey: return "Frontier-model notes, your own key"
        case .semanticMemory: return "Search meetings by meaning"
        }
    }

    /// The upgrade sheet's icon for this feature.
    var symbol: String {
        switch self {
        case .speakerSplit: return "person.2"
        case .askMeeting: return "questionmark.bubble"
        case .reshapeSummary: return "arrow.2.squarepath"
        case .followUpDraft: return "paperplane"
        case .actionTracking: return "checklist"
        case .polishPass: return "wand.and.stars"
        case .customTemplates: return "rectangle.stack"
        case .advancedExport: return "square.and.arrow.up"
        case .calendarContext: return "calendar"
        case .byoCloudKey: return "cloud"
        case .semanticMemory: return "sparkle.magnifyingglass"
        }
    }

    /// The headline the upgrade sheet leads with when this feature is what
    /// the user tapped — sell the outcome, not the mechanism.
    var heroLine: String {
        switch self {
        case .speakerSplit: return "Put a name on every voice."
        case .askMeeting: return "Ask your meeting anything."
        case .reshapeSummary: return "Notes in exactly your shape."
        case .followUpDraft: return "The follow-up, already written."
        case .actionTracking: return "Every promise, tracked."
        case .polishPass: return "Transcripts at maximum accuracy."
        case .customTemplates: return "Notes that follow your format."
        case .advancedExport: return "Take your meetings anywhere."
        case .calendarContext: return "Meetings that name themselves."
        case .byoCloudKey: return "Your key, your frontier model."
        case .semanticMemory: return "Find it by meaning."
        }
    }
}

// MARK: - Entitlement states

/// What this install may do. Pro features never expire once bought — a Pro
/// license past its update window keeps every feature and merely stops
/// receiving new builds (see `coversUpdates(publishedOn:)`).
enum Entitlement: Equatable {
    case free
    case trial(expires: Date)
    case pro(updatesThrough: Date)
    case lifetime
}

/// A successful activation, as stored locally. Written once at activation —
/// the app never contacts the licensing server again unless the user
/// explicitly re-validates after buying a renewal.
struct LicenseRecord: Codable, Equatable {
    enum Tier: String, Codable { case pro, lifetime }
    var key: String
    var activationID: String
    var tier: Tier
    var purchased: Date
    /// End of the included 12 months of updates. Nil for lifetime.
    var updatesThrough: Date?
}

/// Opens the upgrade sheet; `feature` is what the user tapped, if anything.
struct UpgradePrompt: Identifiable, Equatable {
    let id = UUID()
    var feature: ProFeature?
}

// MARK: - Pricing (single source of truth for UI copy)

enum Pricing {
    static let earlyBird = "$49"
    static let regular = "$59"
    static let lifetime = "$149"
    static let renewal = "$29"
    static let trialDays = 14
    /// The website's pricing section — the fallback if the Freemius store ids
    /// are ever cleared, and where Lifetime is also explained.
    static let pricingURL = URL(string: "https://sealformac.com/#pricing")!
}

// MARK: - Service

/// The single source of truth for free / trial / Pro / lifetime. Local-only:
/// state persists as a MAC-signed JSON file in Application Support, integrity
/// is a Keychain-held random key, and nothing here ever touches the network.
/// Tampering or corruption degrades to `.free` — never a crash, never any
/// effect on meetings, which live elsewhere and are not this class's to touch.
///
/// A deliberately honest design point: wiping app data resets the trial. We
/// don't fingerprint the machine or phone home to prevent that; the paying
/// audience is buying trust, not DRM.
final class EntitlementService: ObservableObject {
    @Published private(set) var entitlement: Entitlement = .free
    /// Non-nil while the upgrade sheet should be on screen.
    @Published var upgradePrompt: UpgradePrompt?
#if DEBUG
    /// Manual-QA override (Settings → License, debug builds only): forces the
    /// derived state so every gated surface can be walked through the whole
    /// matrix on one machine (YAR-102). Ephemeral — never persisted, gone on
    /// relaunch, compiled out of release builds entirely.
    @Published var debugForcedEntitlement: Entitlement? { didSet { refresh() } }
#endif

    private struct Persisted: Codable, Equatable {
        var trialStarted: Date?
        /// High-water mark of every clock reading we've seen — winding the
        /// system clock back cannot stretch a trial.
        var lastObserved: Date
        var license: LicenseRecord?
    }

    /// Envelope on disk: the payload plus an HMAC over its exact bytes.
    private struct Envelope: Codable {
        var payload: Data
        var mac: Data
    }

    private var state: Persisted {
        didSet { if state != oldValue { persist() } }
    }

    private let fileURL: URL
    private let macKey: SymmetricKey
    private let now: () -> Date
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The app's instance, for the few non-view seams that can't take an
    /// injected reference (AppSettings.usingCloudNotes). Set only by the app
    /// path below — test instances never touch it.
    static private(set) var shared: EntitlementService?

    /// App-wide instance. Tests use the designated initializer with a temp
    /// directory, a fixed key, and a controllable clock.
    convenience init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Seal", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("entitlement.json"),
                  macKey: Self.keychainMACKey(),
                  now: Date.init)
        Self.shared = self
    }

    init(fileURL: URL, macKey: SymmetricKey, now: @escaping () -> Date) {
        self.fileURL = fileURL
        self.macKey = macKey
        self.now = now
        self.state = Persisted(trialStarted: nil, lastObserved: now(), license: nil)
        if let loaded = Self.load(from: fileURL, key: macKey, decoder: decoder) {
            state = loaded
        }
        refresh()
    }

    // MARK: Gate API

    /// The one question UI code may ask. Computed from stored facts (not the
    /// cached `entitlement`) so a trial that lapsed mid-session answers
    /// truthfully without waiting for a `refresh()`.
    func allows(_ feature: ProFeature) -> Bool {
        switch derived() {
        case .free: return false
        case .trial, .pro, .lifetime: return true
        }
    }

    /// Opens the upgrade sheet for a locked feature (no-op when allowed —
    /// callers can invoke unconditionally).
    func requestUpgrade(for feature: ProFeature? = nil) {
        if let feature, allows(feature) { return }
        upgradePrompt = UpgradePrompt(feature: feature)
    }

    // MARK: Trial

    /// A trial exists to be started exactly once, explicitly.
    var trialAvailable: Bool { state.trialStarted == nil && state.license == nil }

    var trialDaysLeft: Int? {
        guard case .trial(let expires) = derived() else { return nil }
        let seconds = expires.timeIntervalSince(effectiveNow())
        return max(0, Int(ceil(seconds / 86_400)))
    }

    func startTrial() {
        guard trialAvailable else { return }
        state.trialStarted = effectiveNow()
        refresh()
    }

    // MARK: License

    var license: LicenseRecord? { state.license }

    /// Records a successful activation (the network part lives in
    /// `LicenseClient` — by the time this is called, Polar has said yes).
    func apply(license: LicenseRecord) {
        state.license = license
        refresh()
    }

    /// Deactivation: back to free (or nothing — the trial does not revive).
    func clearLicense() {
        state.license = nil
        refresh()
    }

    /// Whether this install's license covers a build published on `date` —
    /// the Sparkle update-window rule (YAR-99). Free installs always update:
    /// every feature they use is free in every build.
    func coversUpdates(publishedOn date: Date) -> Bool {
        switch derived() {
        case .free, .trial, .lifetime: return true
        case .pro(let updatesThrough): return date <= updatesThrough
        }
    }

    /// Re-derives the published state and advances the clock high-water mark.
    /// Cheap; call on init, on user-visible licensing moments, and when the
    /// sheet or License pane appears.
    func refresh() {
        state.lastObserved = effectiveNow()
        let value = derived()
        if entitlement != value { entitlement = value }
    }

    // MARK: - Derivation

    private func derived() -> Entitlement {
#if DEBUG
        if let forced = debugForcedEntitlement { return forced }
#endif
        if let license = state.license {
            switch license.tier {
            case .lifetime: return .lifetime
            case .pro: return .pro(updatesThrough: license.updatesThrough ?? license.purchased)
            }
        }
        if let started = state.trialStarted {
            let expires = started.addingTimeInterval(TimeInterval(Pricing.trialDays) * 86_400)
            if effectiveNow() < expires { return .trial(expires: expires) }
        }
        return .free
    }

    /// The clock, immune to being wound backwards.
    private func effectiveNow() -> Date {
        max(now(), state.lastObserved)
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let payload = try encoder.encode(state)
            let mac = Data(HMAC<SHA256>.authenticationCode(for: payload, using: macKey))
            let data = try encoder.encode(Envelope(payload: payload, mac: mac))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Entitlements: persist failed — \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL, key: SymmetricKey, decoder: JSONDecoder) -> Persisted? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.payload, using: key),
              let state = try? decoder.decode(Persisted.self, from: envelope.payload) else {
            // Corrupt or edited by hand: behave like a fresh install. Never a
            // crash, and meetings are unaffected (they live elsewhere).
            NSLog("Entitlements: stored state failed verification — continuing as free")
            return nil
        }
        return state
    }

    /// The HMAC key lives in the Keychain (generated once per Mac). Under
    /// test the Keychain reads empty (see `Keychain.isUnderTest`), so each
    /// test-host launch gets an ephemeral key — exactly what tests want.
    private static func keychainMACKey() -> SymmetricKey {
        let account = "entitlementMAC"
        if let stored = Keychain.get(account: account),
           let data = Data(base64Encoded: stored) {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        Keychain.set(data.base64EncodedString(), account: account)
        return key
    }
}
