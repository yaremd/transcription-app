import XCTest
import CryptoKit
@testable import Seal

/// The update-window rule (YAR-99): who may install which build. The app
/// never blocks — only updates published outside a Pro license's year are
/// declined, with a message instead of a silent nothing.
final class UpdatePolicyTests: XCTestCase {

    private let day: TimeInterval = 86_400

    func testCoveredUpdateProceeds() {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let message = UpdatePolicy.declineMessage(published: cutoff.addingTimeInterval(-30 * day),
                                                  covers: { $0 <= cutoff })
        XCTAssertNil(message)
    }

    func testUncoveredUpdateDeclinesWithRenewalMessage() {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let message = UpdatePolicy.declineMessage(published: cutoff.addingTimeInterval(30 * day),
                                                  covers: { $0 <= cutoff })
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Renew") == true, "the decline must point at the renewal")
        XCTAssertTrue(message?.contains("Nothing expires") == true, "and must say the app keeps working")
    }

    func testMissingPubDateFailsOpen() {
        // A malformed appcast must never strand users — see the note in
        // UpdatePolicy about why open beats closed here.
        XCTAssertNil(UpdatePolicy.declineMessage(published: nil, covers: { _ in false }))
    }

    func testParsesTheAppcastsOwnDateFormat() throws {
        // The exact shape release.sh writes: date -u "+%a, %d %b %Y %H:%M:%S +0000"
        let parsed = try XCTUnwrap(UpdatePolicy.parseRFC822("Tue, 11 Aug 2026 13:16:18 +0000"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: parsed)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 11)
        XCTAssertEqual(parts.hour, 13)

        XCTAssertNil(UpdatePolicy.parseRFC822(nil))
        XCTAssertNil(UpdatePolicy.parseRFC822("not a date"))
    }

    /// End-to-end with a real entitlement: the window moves with the license.
    func testWindowFollowsTheLicense() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdatePolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let service = EntitlementService(fileURL: dir.appendingPathComponent("e.json"),
                                         macKey: SymmetricKey(data: Data(repeating: 3, count: 32)),
                                         now: { clock })
        service.apply(license: LicenseRecord(key: "K", activationID: "a", tier: .pro,
                                             purchased: clock,
                                             updatesThrough: clock.addingTimeInterval(365 * day)))

        XCTAssertNil(UpdatePolicy.declineMessage(published: clock.addingTimeInterval(100 * day),
                                                 covers: service.coversUpdates(publishedOn:)))
        XCTAssertNotNil(UpdatePolicy.declineMessage(published: clock.addingTimeInterval(400 * day),
                                                    covers: service.coversUpdates(publishedOn:)))

        service.apply(license: LicenseRecord(key: "K2", activationID: "b", tier: .lifetime,
                                             purchased: clock, updatesThrough: nil))
        XCTAssertNil(UpdatePolicy.declineMessage(published: clock.addingTimeInterval(4_000 * day),
                                                 covers: service.coversUpdates(publishedOn:)),
                     "lifetime never declines")
    }
}
