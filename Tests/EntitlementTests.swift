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

    /// The 2026-08-12 lesson as a permanent regression test: the founder's
    /// real license was wiped by a service that read the file with a
    /// different key (the test host's ephemeral one) and then persisted its
    /// fresh-free state over it. A service that couldn't verify the file must
    /// never replace it — reading wrong is survivable, writing wrong is not.
    func testWrongKeyReaderNeverOverwritesTheRealLicense() {
        makeService().apply(license: proLicense())

        let otherKey = SymmetricKey(data: Data(repeating: 9, count: 32))
        let wrongKeyReader = EntitlementService(fileURL: fileURL, macKey: otherKey) { [self] in clock }
        XCTAssertEqual(wrongKeyReader.entitlement, .free)
        wrongKeyReader.refresh()   // the exact write path that did the damage

        let recovered = makeService()
        XCTAssertTrue(recovered.allows(.askMeeting), "the real license must survive a wrong-key reader")
        XCTAssertEqual(recovered.license?.activationID, "act-1")
    }

    /// And the cause behind that lesson: the app hosts the unit tests, so the
    /// app-wide initializer runs at test startup — under test it must point
    /// at a throwaway file, never the user's real state.
    func testTestHostStateIsIsolatedFromTheRealFile() {
        let testHost = EntitlementService.stateFileURL(underTest: true)
        let real = EntitlementService.stateFileURL(underTest: false)
        XCTAssertTrue(testHost.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertNotEqual(testHost, real)
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
        // The live API's actual invalid-key shape (verified 2026-08-11).
        let invalid = """
        {"error": {"type": "InvalidArgument", "message": "Invalid license key.",
         "code": "invalid_license_key", "http": 400}}
        """
        XCTAssertEqual(FreemiusLicenseClient.rejection(from: Data(invalid.utf8)), .invalidKey)

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

// MARK: - Re-activation must not renew the update window (YAR-106)

extension EntitlementTests {

    private func proRecord(key: String = "SEAL-KEY",
                           purchased: Date,
                           activationID: String = "install-1",
                           tier: LicenseRecord.Tier = .pro) -> LicenseRecord {
        LicenseRecord(key: key, activationID: activationID, tier: tier, purchased: purchased,
                      updatesThrough: tier == .lifetime ? nil
                        : Calendar.current.date(byAdding: .year, value: 1, to: purchased))
    }

    /// The loophole, in the shape it was observed on 2026-08-12: a licence
    /// bought on day 0, re-activated a year later, coming back stamped with
    /// the activation date because the response carried no creation date.
    /// Without reconciliation that buys another free year, every year.
    func testReActivationDoesNotPushTheWindowOut() {
        let bought = Date(timeIntervalSince1970: 1_800_000_000)
        let stored = proRecord(purchased: bought)
        // What the Date() fallback produces on a re-activation a year later.
        let reActivation = proRecord(purchased: bought.addingTimeInterval(365 * 86_400),
                                     activationID: "install-2")

        let result = EntitlementService.reconciled(incoming: reActivation, stored: stored)

        XCTAssertEqual(result.purchased, bought, "the purchase moment cannot move forward")
        XCTAssertEqual(result.updatesThrough, stored.updatesThrough,
                       "a re-activation must not renew the year of updates")
        XCTAssertEqual(result.activationID, "install-2",
                       "the new install id is real news and must still be taken")
    }

    /// The date is only distrusted when it moves the *wrong* way. A response
    /// that carries the true creation date is believed.
    func testEarlierPurchaseDateIsTakenAsRealData() {
        let stored = proRecord(purchased: Date(timeIntervalSince1970: 1_800_000_000))
        let corrected = proRecord(purchased: Date(timeIntervalSince1970: 1_700_000_000))

        let result = EntitlementService.reconciled(incoming: corrected, stored: stored)

        XCTAssertEqual(result.purchased, corrected.purchased)
        XCTAssertEqual(result.updatesThrough, corrected.updatesThrough)
    }

    /// A window the user already has is a floor: a renewal that legitimately
    /// extended it is not clawed back by a later re-activation.
    func testAnExtendedWindowSurvivesAReActivation() {
        let bought = Date(timeIntervalSince1970: 1_800_000_000)
        var renewed = proRecord(purchased: bought)
        renewed.updatesThrough = Calendar.current.date(byAdding: .year, value: 2, to: bought)

        let reActivation = proRecord(purchased: bought.addingTimeInterval(400 * 86_400))
        let result = EntitlementService.reconciled(incoming: reActivation, stored: renewed)

        XCTAssertEqual(result.updatesThrough, renewed.updatesThrough,
                       "the renewed window is the floor, not something to shorten")
    }

    /// A different key is a different purchase — nothing to reconcile against.
    func testADifferentKeyIsLeftAlone() {
        let stored = proRecord(key: "OLD-KEY", purchased: Date(timeIntervalSince1970: 1_700_000_000))
        let bought = proRecord(key: "NEW-KEY", purchased: Date(timeIntervalSince1970: 1_800_000_000))

        let result = EntitlementService.reconciled(incoming: bought, stored: stored)

        XCTAssertEqual(result.purchased, bought.purchased, "a new licence is a new purchase")
        XCTAssertEqual(result.updatesThrough, bought.updatesThrough)
    }

    func testFirstActivationHasNothingToReconcile() {
        let bought = proRecord(purchased: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(EntitlementService.reconciled(incoming: bought, stored: nil), bought)
    }

    /// Lifetime has no window to protect, and must never acquire one.
    func testLifetimeKeepsItsOpenEndedWindow() {
        let bought = Date(timeIntervalSince1970: 1_800_000_000)
        let stored = proRecord(purchased: bought, tier: .lifetime)
        let reActivation = proRecord(purchased: bought.addingTimeInterval(500 * 86_400),
                                     tier: .lifetime)

        let result = EntitlementService.reconciled(incoming: reActivation, stored: stored)

        XCTAssertEqual(result.purchased, bought)
        XCTAssertNil(result.updatesThrough, "lifetime never gains an expiry")
    }

    /// End to end through the service, since `apply` is what production calls.
    func testApplyReconcilesAndTheEntitlementFollows() throws {
        let service = makeService()
        let bought = clock
        service.apply(license: proRecord(purchased: bought))

        // A year later, deactivate and re-activate — the response stamps today.
        clock = bought.addingTimeInterval(360 * 86_400)
        service.apply(license: proRecord(purchased: clock, activationID: "install-2"))

        let expected = Calendar.current.date(byAdding: .year, value: 1, to: bought)
        XCTAssertEqual(service.license?.updatesThrough, expected)

        // And the update-window rule agrees: a build published after the
        // original year is still declined.
        XCTAssertFalse(service.coversUpdates(publishedOn: bought.addingTimeInterval(400 * 86_400)),
                       "re-activating must not buy access to newer builds")
    }
}
