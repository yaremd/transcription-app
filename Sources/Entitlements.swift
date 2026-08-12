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

    /// One line for the upgrade sheet's feature list.
    var blurb: String {
        switch self {
        case .speakerSplit: return "Who said what — you vs. everyone else"
        case .askMeeting: return "Ask questions across a meeting's transcript"
        case .reshapeSummary: return "Regenerate notes in a different shape"
        case .followUpDraft: return "A ready-to-send follow-up, drafted locally"
        case .actionTracking: return "Your action items, tracked across meetings"
        case .polishPass: return "Re-transcribe a finished meeting at maximum accuracy"
        case .customTemplates: return "Your own note templates (built-ins stay free)"
        case .advancedExport: return "DOCX, SRT, and Obsidian / Notion handoff"
        case .calendarContext: return "Titles and attendees from your calendar"
        case .byoCloudKey: return "Optional frontier-model notes with your own API key"
        case .semanticMemory: return "Search every meeting by meaning, not keywords"
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
    /// The website's pricing section; checkout buttons point here until the
    /// Polar storefront is live (YAR-95), and Lifetime always sells here.
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
    ///
    /// The test HOST is the trap this guards against (2026-08-12, the lesson
    /// that wiped the founder's own license): the app hosts the unit tests,
    /// so this initializer runs at test startup too — and under test the
    /// Keychain deliberately reads empty, which minted a fresh integrity key,
    /// made the real, valid license file look tampered, and persisted a clean
    /// free state over it. Under test, the real file must not even be opened.
    convenience init() {
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.init(fileURL: Self.stateFileURL(underTest: underTest),
                  macKey: underTest ? SymmetricKey(size: .bits256) : Self.keychainMACKey(),
                  now: Date.init)
        Self.shared = self
    }

    /// Where the app-wide instance keeps its state: the real Application
    /// Support file for the app, an isolated throwaway for the test host.
    static func stateFileURL(underTest: Bool) -> URL {
        let fm = FileManager.default
        if underTest {
            return fm.temporaryDirectory
                .appendingPathComponent("Seal-test-host-entitlement.json")
        }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Seal", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("entitlement.json")
    }

    /// Whether this instance may write the state file. Armed when the file
    /// loaded cleanly or simply didn't exist yet; DISARMED when a file was
    /// present but failed verification — a service that couldn't read the
    /// state has no business replacing it (the second half of the 2026-08-12
    /// lesson: the wipe needed both a wrong key AND an eager persist). An
    /// explicit user action — starting the trial, activating, deactivating —
    /// re-arms it, because at that point the user is genuinely writing new
    /// state.
    private var persistArmed: Bool

    init(fileURL: URL, macKey: SymmetricKey, now: @escaping () -> Date) {
        self.fileURL = fileURL
        self.macKey = macKey
        self.now = now
        let fresh = Persisted(trialStarted: nil, lastObserved: now(), license: nil)
        switch Self.load(from: fileURL, key: macKey, decoder: decoder) {
        case .loaded(let stored):
            persistArmed = true
            state = stored
        case .absent:
            persistArmed = true
            state = fresh
        case .failedVerification:
            persistArmed = false
            state = fresh
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
        persistArmed = true
        state.trialStarted = effectiveNow()
        refresh()
    }

    // MARK: License

    var license: LicenseRecord? { state.license }

    /// Records a successful activation (the network part lives in
    /// `LicenseClient` — by the time this is called, Polar has said yes).
    func apply(license: LicenseRecord) {
        persistArmed = true
        state.license = license
        refresh()
    }

    /// Deactivation: back to free (or nothing — the trial does not revive).
    func clearLicense() {
        persistArmed = true
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
        guard persistArmed else { return }
        do {
            let payload = try encoder.encode(state)
            let mac = Data(HMAC<SHA256>.authenticationCode(for: payload, using: macKey))
            let data = try encoder.encode(Envelope(payload: payload, mac: mac))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Entitlements: persist failed — \(error.localizedDescription)")
        }
    }

    private enum LoadResult {
        case loaded(Persisted)
        case absent
        case failedVerification
    }

    private static func load(from url: URL, key: SymmetricKey, decoder: JSONDecoder) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .absent }
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.payload, using: key),
              let state = try? decoder.decode(Persisted.self, from: envelope.payload) else {
            // Corrupt, edited by hand — or read with the wrong key. Behave
            // like a fresh install in memory, but leave the FILE alone: it
            // may be someone's real license seen through the wrong key, and
            // overwriting it is how a paying user gets silently unlicensed.
            NSLog("Entitlements: stored state failed verification — continuing as free, file preserved")
            return .failedVerification
        }
        return .loaded(state)
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
