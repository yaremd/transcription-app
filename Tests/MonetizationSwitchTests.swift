import XCTest
import CryptoKit
@testable import Seal

/// One switch decides whether Seal charges for anything. Off, a free install
/// is allowed everything and no paid surface can appear; on, the Free/Pro
/// line behaves as the matrix tests pin it. Both directions are checked so
/// flipping it back is a one-line change, not an archaeology project.
final class MonetizationSwitchTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonetizationSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func service(monetized: Bool) -> EntitlementService {
        let s = EntitlementService(fileURL: directory.appendingPathComponent("e.json"), macKey: key) { [self] in clock }
        s.isMonetized = monetized
        return s
    }

    func testTheShippingAppIsFree() {
        XCTAssertFalse(Monetization.enabled)
        XCTAssertFalse(EntitlementService(fileURL: directory.appendingPathComponent("d.json"), macKey: key) { [self] in clock }.isMonetized)
    }

    func testWithMoneyOffAFreeInstallIsAllowedEverythingAndNeverSold() {
        let s = service(monetized: false)
        XCTAssertEqual(s.entitlement, .free)
        XCTAssertTrue(ProFeature.allCases.allSatisfy(s.allows))
        XCTAssertFalse(s.trialAvailable)
        s.requestUpgrade(for: .askMeeting)
        XCTAssertNil(s.upgradePrompt, "the upgrade sheet must never open while nothing is sold")
        XCTAssertTrue(s.coversUpdates(publishedOn: clock.addingTimeInterval(10_000 * 86_400)))
    }

    func testWithMoneyOffALapsedPaidLicenseStillGetsEveryUpdate() {
        let s = service(monetized: false)
        s.apply(license: LicenseRecord(key: "K", activationID: "a", tier: .pro,
                                       purchased: clock.addingTimeInterval(-800 * 86_400),
                                       updatesThrough: clock.addingTimeInterval(-435 * 86_400)))
        if case .pro = s.entitlement {} else { XCTFail("the key is still honoured and recorded") }
        XCTAssertTrue(s.coversUpdates(publishedOn: clock))
        XCTAssertTrue(s.allows(.screenContext))
    }

    func testWithMoneyOnAFreeInstallIsGatedAgain() {
        let s = service(monetized: true)
        XCTAssertFalse(s.allows(.askMeeting))
        XCTAssertTrue(s.trialAvailable)
        s.requestUpgrade(for: .askMeeting)
        XCTAssertNotNil(s.upgradePrompt)
    }
}
