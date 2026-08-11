import Foundation
import Sparkle

/// The perpetual-license update window, enforced at the updater (YAR-99):
/// a Pro license includes 12 months of updates. A build published inside the
/// window installs normally; one published after it is declined with a
/// renewal message instead — and the app itself keeps working, forever.
/// Free, trial, and lifetime installs are never declined (a free install's
/// features are free in every build).
///
/// The decision reads each appcast item's pubDate — which release.sh stamps
/// on every release — so this file and that stamp are a pair: an item
/// without a date is treated as covered (failing open can hand an expired
/// license one extra update; failing closed would strand every user on a
/// malformed appcast, which is the far worse bug).
final class UpdatePolicy: NSObject, SPUUpdaterDelegate {
    private let entitlements: EntitlementService

    init(entitlements: EntitlementService) {
        self.entitlements = entitlements
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        let published = updateItem.date ?? Self.parseRFC822(updateItem.dateString)
        if let message = Self.declineMessage(published: published,
                                             covers: entitlements.coversUpdates(publishedOn:)) {
            throw NSError(domain: "SealUpdatePolicy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// The pure decision, testable without Sparkle types. Nil means proceed.
    static func declineMessage(published: Date?, covers: (Date) -> Bool) -> String? {
        guard let published, !covers(published) else { return nil }
        return "This update came out after your license's year of updates. "
            + "Renew for \(Pricing.renewal)/yr in Settings → License to get it — "
            + "or keep using Seal exactly as it is. Nothing expires."
    }

    /// The appcast's pubDate format (RFC 822, as release.sh writes it).
    static func parseRFC822(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: string)
    }
}
