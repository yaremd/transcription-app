import XCTest
import CryptoKit
@testable import Seal

/// The entitlement matrix's automated half (YAR-94/96, feeds YAR-102):
/// state machine, trial lifecycle, clock rollback, persistence integrity.
/// Meetings are never involved — licensing must not be able to touch them.
final class EntitlementTests: XCTestCase {

    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("entitlement.json") }

    private func makeService() -> EntitlementService {
        EntitlementService(fileURL: fileURL, macKey: key) { [self] in clock }
    }

    private func advance(days: Double) {
        clock = clock.addingTimeInterval(days * 86_400)
    }

    private func proLicense(purchased: Date? = nil) -> LicenseRecord {
        let bought = purchased ?? clock
        return LicenseRecord(key: "SEAL-TEST-KEY-12345678", activationID: "act-1", tier: .pro,
                             purchased: bought,
                             updatesThrough: bought.addingTimeInterval(365 * 86_400))
    }

    // MARK: - Fresh install

    func testFreshInstallIsFreeAndAllowsNoProFeature() {
        let service = makeService()
        XCTAssertEqual(service.entitlement, .free)
        XCTAssertTrue(service.trialAvailable)
        for feature in ProFeature.allCases {
            XCTAssertFalse(service.allows(feature), "\(feature) must be locked on free")
        }
    }

    func testRequestUpgradeOpensSheetOnlyWhenLocked() {
        let service = makeService()
        service.requestUpgrade(for: .askMeeting)
        XCTAssertEqual(service.upgradePrompt?.feature, .askMeeting)

        service.upgradePrompt = nil
        service.startTrial()
        service.requestUpgrade(for: .askMeeting)
        XCTAssertNil(service.upgradePrompt, "no upsell for something the user already has")
    }

    // MARK: - Trial

    func testTrialLifecycle() {
        let service = makeService()
        service.startTrial()

        guard case .trial(let expires) = service.entitlement else {
            return XCTFail("expected trial, got \(service.entitlement)")
        }
        XCTAssertEqual(expires.timeIntervalSince(clock), 14 * 86_400, accuracy: 1)
        XCTAssertTrue(ProFeature.allCases.allSatisfy(service.allows), "trial unlocks everything")
        XCTAssertEqual(service.trialDaysLeft, 14)
        XCTAssertFalse(service.trialAvailable, "a started trial can't be started again")

        advance(days: 13)
        XCTAssertTrue(service.allows(.askMeeting))

        advance(days: 2)
        service.refresh()
        XCTAssertEqual(service.entitlement, .free)
        XCTAssertFalse(service.allows(.askMeeting))
        XCTAssertFalse(service.trialAvailable, "expiry must not re-arm the trial")
        XCTAssertNil(service.trialDaysLeft)
    }

    func testAllowsLapsesMidSessionWithoutRefresh() {
        let service = makeService()
        service.startTrial()
        advance(days: 15)
        // No refresh() — allows() must answer from facts, not the cached state.
        XCTAssertFalse(service.allows(.askMeeting))
    }

    func testClockRollbackCannotExtendTrial() {
        let service = makeService()
        service.startTrial()

        advance(days: 10)
        service.refresh()                    // high-water mark: day 10
        XCTAssertTrue(service.allows(.askMeeting))

        advance(days: -6)                    // user winds the clock back to day 4
        service.refresh()
        XCTAssertEqual(service.trialDaysLeft, 4, "remaining time judged from the high-water mark")

        advance(days: 5)                     // real clock: day 9 — but high water stays 10
        XCTAssertTrue(service.allows(.askMeeting))
        advance(days: 6)                     // real clock: day 15
        XCTAssertFalse(service.allows(.askMeeting), "rollback must not add days")
    }

    // MARK: - Licenses

    func testProLicenseUnlocksFeaturesAndBoundsUpdates() {
        let service = makeService()
        let license = proLicense()
        service.apply(license: license)

        XCTAssertEqual(service.entitlement, .pro(updatesThrough: license.updatesThrough!))
        XCTAssertTrue(ProFeature.allCases.allSatisfy(service.allows))

        XCTAssertTrue(service.coversUpdates(publishedOn: clock.addingTimeInterval(180 * 86_400)))
        XCTAssertFalse(service.coversUpdates(publishedOn: clock.addingTimeInterval(400 * 86_400)))

        // Features never expire with the update window — only updates do.
        advance(days: 400)
        service.refresh()
        XCTAssertTrue(service.allows(.askMeeting), "a bought feature stays bought")
    }

    func testLifetimeCoversEverythingForever() {
        let service = makeService()
        service.apply(license: LicenseRecord(key: "SEAL-LIFE", activationID: "act-2",
                                             tier: .lifetime, purchased: clock, updatesThrough: nil))
        XCTAssertEqual(service.entitlement, .lifetime)
        XCTAssertTrue(service.coversUpdates(publishedOn: clock.addingTimeInterval(3_650 * 86_400)))
    }

    func testDeactivationReturnsToFreeWithoutRevivingTrial() {
        let service = makeService()
        service.startTrial()
        advance(days: 20)                    // trial long gone
        service.apply(license: proLicense())
        XCTAssertTrue(service.allows(.askMeeting))

        service.clearLicense()
        XCTAssertEqual(service.entitlement, .free)
        XCTAssertFalse(service.allows(.askMeeting))
        XCTAssertFalse(service.trialAvailable)
    }

    func testFreeInstallAlwaysCoversUpdates() {
        // Free features are free in every build — never hold an update back.
        XCTAssertTrue(makeService().coversUpdates(publishedOn: clock.addingTimeInterval(9_999 * 86_400)))
    }

    // MARK: - Persistence

    func testStateSurvivesRelaunch() {
        makeService().startTrial()
        advance(days: 3)

        let relaunched = makeService()
        guard case .trial = relaunched.entitlement else {
            return XCTFail("trial should persist across launches, got \(relaunched.entitlement)")
        }
        XCTAssertEqual(relaunched.trialDaysLeft, 11)

        relaunched.apply(license: proLicense())
        let third = makeService()
        XCTAssertTrue(third.allows(.askMeeting))
        XCTAssertEqual(third.license?.activationID, "act-1")
    }

    func testTamperedFileDegradesToFreeWithoutCrashing() throws {
        makeService().apply(license: proLicense())

        var bytes = try Data(contentsOf: fileURL)
        let index = bytes.count / 2
        bytes[index] = bytes[index] &+ 1     // flip one byte anywhere in the envelope
        try bytes.write(to: fileURL)

        let service = makeService()
        XCTAssertEqual(service.entitlement, .free, "edited state must not stay licensed")
        XCTAssertTrue(service.trialAvailable, "recovers as a fresh, working install")

        // And the recovered install persists cleanly again.
        service.startTrial()
        guard case .trial = makeService().entitlement else {
            return XCTFail("recovery after tamper should persist normally")
        }
    }

    func testWrongMACKeyReadsAsFree() {
        makeService().apply(license: proLicense())
        let otherKey = SymmetricKey(data: Data(repeating: 9, count: 32))
        let service = EntitlementService(fileURL: fileURL, macKey: otherKey) { [self] in clock }
        XCTAssertEqual(service.entitlement, .free)
    }

    // MARK: - Polar response mapping

    func testFreemiusActivationParsing() throws {
        // The plan name names the tier — Freemius's activation response shape.
        let lifetime = """
        {"install_id": 90210, "install_api_token": "t",
         "license_plan_name": "Lifetime",
         "license": {"created": "2026-08-01 10:00:00"}}
        """
        let record = try FreemiusLicenseClient.record(fromActivation: Data(lifetime.utf8), key: "K-1")
        XCTAssertEqual(record.activationID, "90210")
        XCTAssertEqual(record.tier, .lifetime)
        XCTAssertNil(record.updatesThrough)

        // Any other plan is Pro, with a one-year window from the license's
        // OWN purchase date — never the activation date.
        let pro = """
        {"install_id": "90211", "license_plan_name": "Pro",
         "license": {"created": "2026-08-01 10:00:00"}}
        """
        let proRecord = try FreemiusLicenseClient.record(fromActivation: Data(pro.utf8), key: "K-2")
        XCTAssertEqual(proRecord.tier, .pro)
        let purchaseDate = try XCTUnwrap(FreemiusLicenseClient.parseFreemiusDate("2026-08-01 10:00:00"))
        let expected = Calendar.current.date(byAdding: .year, value: 1, to: purchaseDate)!
        let window = try XCTUnwrap(proRecord.updatesThrough)
        XCTAssertEqual(window.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)

        XCTAssertThrowsError(try FreemiusLicenseClient.record(fromActivation: Data("{}".utf8), key: "K"))
    }

    func testFreemiusRejectionMapping() {
        let quota = """
        {"error": {"message": "Maximum number of activations reached."}}
        """
        XCTAssertEqual(FreemiusLicenseClient.rejection(from: Data(quota.utf8)), .activationLimitReached)

        let other = """
        {"error": {"message": "License is blocked."}}
        """
        XCTAssertEqual(FreemiusLicenseClient.rejection(from: Data(other.utf8)), .rejected("License is blocked."))

        XCTAssertNil(FreemiusLicenseClient.rejection(from: Data("{}".utf8)))
    }

    func testMachineUIDIsStableAnd32Hex() {
        let uid = FreemiusLicenseClient.machineUID()
        XCTAssertEqual(uid.count, 32)
        XCTAssertTrue(uid.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(uid, FreemiusLicenseClient.machineUID(), "must be stable per machine")
    }
}
