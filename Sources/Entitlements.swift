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
        case .advancedExport: return "Word, subtitles, and Obsidian Markdown"
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
    ///
    /// The test HOST is the trap this guards against (2026-08-12, the lesson
    /// that wiped the founder's own license): the app hosts the unit tests,
    /// so this initializer runs at test startup too — and under test the
    /// Keychain deliberately reads empty, which minted a fresh integrity key,
    /// made the real, valid license file look tampered, and persisted a clean
    /// free state over it. Under test, the real file must not even be opened.
    convenience init() {
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // Demo runs are isolated for the same reason the test host is, and it
        // is the same failure if they aren't: a throwaway state file combined
        // with the real Keychain key is what wiped a valid license once. An
        // ephemeral key means the Keychain is never read and never minted.
        let isolated = underTest || DemoMode.isActive
        self.init(fileURL: Self.stateFileURL(underTest: underTest),
                  macKey: isolated ? SymmetricKey(size: .bits256) : Self.keychainMACKey(),
                  now: Date.init)
        // Screenshots need the Pro surfaces on show. This is the existing
        // debug override, not a new door into the paid features — and it has
        // to be compiled out of Release for the same reason the override
        // itself is: the property does not exist there. Unguarded, this line
        // broke the Release build outright, which no debug build could show.
#if DEBUG
        if DemoMode.isActive {
            debugForcedEntitlement = .pro(updatesThrough: Date(timeIntervalSinceNow: 60 * 60 * 24 * 365))
        }
#endif
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
        if let demo = DemoMode.container {
            return demo.appendingPathComponent("entitlement.json")
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
    /// `LicenseClient` — by the time this is called, Freemius has said yes).
    func apply(license: LicenseRecord) {
        persistArmed = true
        state.license = Self.reconciled(incoming: license, stored: state.license)
        refresh()
    }

    /// Keeps a re-activation from moving the purchase date forward (YAR-106).
    ///
    /// `FreemiusLicenseClient.record(fromActivation:)` falls back to `Date()`
    /// when the response carries no creation date, and the live *re*-activation
    /// response does exactly that — observed 2026-08-12, where a licence issued
    /// on Aug 11 came back stamped Aug 12 and its update window moved out a day
    /// with it. Left alone that is a standing loophole: deactivate and
    /// re-activate once a year and the year of updates renews itself forever.
    ///
    /// A purchase happens once. If we already recorded when, a *later* date
    /// arriving from the same key is the fallback firing rather than news, so
    /// the stored date wins and the window is recomputed from it. An earlier or
    /// equal date is real data and is taken as-is.
    ///
    /// The window is never shortened either — whatever the user already had is
    /// the floor, so a renewal that legitimately extended it survives a later
    /// re-activation. The one case this is deliberately strict about is a
    /// renewal whose response *also* omits the date: that window will not
    /// extend, and it needs handling by hand. That is the safe direction to
    /// err while renewals do not exist yet (they begin summer 2027), and it is
    /// visible as a support question rather than silent as revenue.
    static func reconciled(incoming: LicenseRecord, stored: LicenseRecord?) -> LicenseRecord {
        guard let stored, stored.key == incoming.key,
              incoming.purchased > stored.purchased else { return incoming }

        var fixed = incoming
        fixed.purchased = stored.purchased
        if incoming.tier != .lifetime {
            let fromTruePurchase = Calendar.current.date(byAdding: .year, value: 1, to: stored.purchased)
            fixed.updatesThrough = [fromTruePurchase, stored.updatesThrough].compactMap { $0 }.max()
        }
        return fixed
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
