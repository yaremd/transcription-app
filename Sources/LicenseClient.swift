import Foundation

/// The one network seam in licensing. Exactly two user-initiated moments may
/// touch it: activating a key, and re-validating after buying a renewal.
/// Everything else in the app reads the local `LicenseRecord`.
protocol LicenseActivating {
    /// Exchanges a pasted key for an activation record, or throws
    /// `LicenseError`.
    func activate(key: String) async throws -> LicenseRecord
    /// Frees this Mac's activation so the key can be used on another.
    func deactivate(_ record: LicenseRecord) async throws
}

enum LicenseError: LocalizedError, Equatable {
    case invalidKey
    case activationLimitReached
    case offline
    case storefrontNotLive

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "That key wasn't recognized. Check for typos, or reply to your purchase email and we'll sort it out."
        case .activationLimitReached:
            return "This key is already active on two Macs. Deactivate it on one of them (Settings → License), then try again."
        case .offline:
            return "Couldn't reach the license server. Try again when you're online — your notes are unaffected."
        case .storefrontNotLive:
            return "Purchasing opens with v1.0 — this build can't activate keys yet."
        }
    }
}

/// Everything that identifies OUR storefront on Polar. One paste fills this
/// in when the org exists (YAR-95): the organization ID, plus the license-key
/// benefit ID of each product — the activation response's `benefit_id` is how
/// the app tells a $149 Lifetime key from a $49/$59 Pro key. None of these
/// are secrets; Polar's customer-portal endpoints are deliberately public.
enum SealStore {
    static let organizationID = ""
    static let proBenefitID = ""
    static let lifetimeBenefitID = ""
    /// Direct checkout links, once the products exist. Until then the Buy
    /// buttons fall back to the website's pricing section.
    static let checkoutPro: URL? = nil
    static let checkoutLifetime: URL? = nil

    static var isLive: Bool { !organizationID.isEmpty }
}

/// Polar.sh license activation (YAR-95). Polar is the merchant of record;
/// its License Key API gives us activate / validate / deactivate with an
/// activation limit per key. One activation call at purchase time, then the
/// app never phones home again.
///
/// Until `SealStore` is filled in, every call fails fast with
/// `.storefrontNotLive` so the UI stays honest.
struct PolarLicenseClient: LicenseActivating {

    private let api = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func activate(key: String) async throws -> LicenseRecord {
        guard SealStore.isLive else { throw LicenseError.storefrontNotLive }

        var request = URLRequest(url: api.appendingPathComponent("activate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": key.trimmingCharacters(in: .whitespacesAndNewlines),
            "organization_id": SealStore.organizationID,
            "label": Host.current().localizedName ?? "Mac",
        ])

        let (data, response) = try await send(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200, 201:
            return try Self.record(fromActivation: data, key: key)
        case 403:
            throw LicenseError.activationLimitReached
        case 404, 422:
            throw LicenseError.invalidKey
        default:
            throw LicenseError.offline
        }
    }

    func deactivate(_ record: LicenseRecord) async throws {
        guard SealStore.isLive else { throw LicenseError.storefrontNotLive }

        var request = URLRequest(url: api.appendingPathComponent("deactivate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": record.key,
            "organization_id": SealStore.organizationID,
            "activation_id": record.activationID,
        ])
        _ = try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw LicenseError.offline
        }
    }

    /// Maps Polar's activation response onto our local record. The response
    /// is `{id: <activation id>, license_key: {benefit_id, created_at, …}}`;
    /// the benefit ID names the product tier. An unknown benefit falls back
    /// to Pro with a log — a config mistake must never brick a paid key.
    /// Updates-through is purchase + 12 months for Pro, open-ended for
    /// Lifetime.
    static func record(fromActivation data: Data, key: String,
                       lifetimeBenefitID: String = SealStore.lifetimeBenefitID) throws -> LicenseRecord {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw LicenseError.invalidKey
        }
        let licenseKey = json["license_key"] as? [String: Any]
        let benefitID = licenseKey?["benefit_id"] as? String

        let tier: LicenseRecord.Tier
        if let benefitID, !lifetimeBenefitID.isEmpty, benefitID == lifetimeBenefitID {
            tier = .lifetime
        } else {
            if let benefitID, !SealStore.proBenefitID.isEmpty, benefitID != SealStore.proBenefitID {
                NSLog("LicenseClient: unrecognized benefit \(benefitID) — treating as Pro")
            }
            tier = .pro
        }

        let purchased: Date
        if let created = licenseKey?["created_at"] as? String,
           let date = ISO8601DateFormatter().date(from: created)
               ?? parseFractionalISO8601(created) {
            purchased = date
        } else {
            purchased = Date()
        }

        return LicenseRecord(
            key: key.trimmingCharacters(in: .whitespacesAndNewlines),
            activationID: id,
            tier: tier,
            purchased: purchased,
            updatesThrough: tier == .lifetime ? nil
                : Calendar.current.date(byAdding: .year, value: 1, to: purchased))
    }

    /// Polar timestamps may carry fractional seconds, which the plain
    /// ISO8601DateFormatter rejects.
    private static func parseFractionalISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
