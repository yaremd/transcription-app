import XCTest
import CryptoKit
@testable import Seal

/// YAR-102's exhaustive half: every state × every gate, the update-window
/// rule per state, the exact trial boundary, and the trust canary. The spot
/// checks live in EntitlementTests; this sweep is table-driven, so a new
/// ProFeature case joins the matrix automatically.
final class EntitlementMatrixTests: XCTestCase {

    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = SymmetricKey(data: Data(repeating: 5, count: 32))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementMatrixTests-\(UUID().uuidString)", isDirectory: true)
        try reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A clean slate between matrix rows: fresh directory, rewound clock.
    private func reset() throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private var fileURL: URL { directory.appendingPathComponent("entitlement.json") }

    private func makeService() -> EntitlementService {
        EntitlementService(fileURL: fileURL, macKey: key) { [self] in clock }
    }

    private func advance(days: Double) {
        clock = clock.addingTimeInterval(days * 86_400)
    }

    private func proLicense() -> LicenseRecord {
        LicenseRecord(key: "SEAL-MATRIX-KEY-1234", activationID: "act-m", tier: .pro,
                      purchased: clock, updatesThrough: clock.addingTimeInterval(365 * 86_400))
    }

    // MARK: - The matrix

    private enum MatrixState: String, CaseIterable {
        case freshFree, trialDay1, trialLastDay, trialExpired
        case proInWindow, proPastWindow, lifetime, deactivated, tampered

        /// The single question every gate asks, answered per state.
        var unlocksProFeatures: Bool {
            switch self {
            case .trialDay1, .trialLastDay, .proInWindow, .proPastWindow, .lifetime:
                return true
            case .freshFree, .trialExpired, .deactivated, .tampered:
                return false
            }
        }
    }

    /// Builds a service living in the given state (fresh directory each time).
    private func service(in state: MatrixState) throws -> EntitlementService {
        switch state {
        case .freshFree:
            return makeService()
        case .trialDay1:
            let s = makeService(); s.startTrial(); advance(days: 1); return s
        case .trialLastDay:
            let s = makeService(); s.startTrial(); advance(days: 13.5); return s
        case .trialExpired:
            let s = makeService(); s.startTrial(); advance(days: 15); return s
        case .proInWindow:
            let s = makeService(); s.apply(license: proLicense()); advance(days: 100); return s
        case .proPastWindow:
            let s = makeService(); s.apply(license: proLicense()); advance(days: 400); return s
        case .lifetime:
            let s = makeService()
            s.apply(license: LicenseRecord(key: "SEAL-LIFE-M", activationID: "act-l",
                                           tier: .lifetime, purchased: clock, updatesThrough: nil))
            return s
        case .deactivated:
            let s = makeService(); s.apply(license: proLicense()); s.clearLicense(); return s
        case .tampered:
            makeService().apply(license: proLicense())
            var bytes = try Data(contentsOf: fileURL)
            bytes[bytes.count / 3] &+= 1
            try bytes.write(to: fileURL)
            return makeService()
        }
    }

    func testEveryStateAnswersEveryGateCorrectly() throws {
        for state in MatrixState.allCases {
            try reset()
            let s = try service(in: state)
            for feature in ProFeature.allCases {
                XCTAssertEqual(s.allows(feature), state.unlocksProFeatures,
                               "\(state.rawValue) × \(feature.rawValue)")
            }
        }
    }

    // MARK: - Update-window rule per state

    func testFreeTrialAndLifetimeAlwaysCoverUpdates() throws {
        for state in [MatrixState.freshFree, .trialDay1, .trialExpired, .lifetime, .tampered] {
            try reset()
            let s = try service(in: state)
            XCTAssertTrue(s.coversUpdates(publishedOn: clock.addingTimeInterval(9_999 * 86_400)),
                          "\(state.rawValue) must never hold an update back")
        }
    }

    func testProUpdateWindowBoundaryIsExact() throws {
        let s = makeService()
        s.apply(license: proLicense())
        guard case .pro(let through) = s.entitlement else {
            return XCTFail("expected pro, got \(s.entitlement)")
        }
        XCTAssertTrue(s.coversUpdates(publishedOn: through),
                      "a build published on the window's last day is covered")
        XCTAssertFalse(s.coversUpdates(publishedOn: through.addingTimeInterval(1)),
                       "one second past the window is not")
    }

    func testProPastWindowKeepsFeaturesButNotNewBuilds() throws {
        let s = try service(in: .proPastWindow)
        XCTAssertTrue(ProFeature.allCases.allSatisfy(s.allows),
                      "a bought feature stays bought after the update window")
        XCTAssertFalse(s.coversUpdates(publishedOn: clock),
                       "a build published today is past the lapsed window")
    }

    // MARK: - Trial boundary

    func testTrialEndsExactlyAtFourteenDays() {
        let s = makeService()
        s.startTrial()
        advance(days: 13.999)
        XCTAssertTrue(s.allows(.askMeeting), "still inside the trial")
        advance(days: 0.001)   // exactly day 14
        XCTAssertFalse(s.allows(.askMeeting), "the boundary itself is expired")
        XCTAssertFalse(s.trialAvailable, "expiry never re-arms the trial")
    }

    // MARK: - Trust canary

    /// History access and raw export must never be gated (the rules atop
    /// Entitlements.swift). This pins the enum: adding a case fails here
    /// first, forcing whoever adds it to re-read those rules deliberately.
    func testProFeatureSetIsTheApprovedPaywallLine() {
        XCTAssertEqual(
            Set(ProFeature.allCases.map(\.rawValue)),
            ["speakerSplit", "askMeeting", "reshapeSummary", "followUpDraft",
             "actionTracking", "polishPass", "customTemplates", "advancedExport",
             "calendarContext", "byoCloudKey", "semanticMemory"],
            "New Pro gate? Re-read the trust rules atop Entitlements.swift — history access and raw export must never join this enum.")
    }
}
