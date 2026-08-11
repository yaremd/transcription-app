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

/// Polar.sh license activation (YAR-95). Polar is the merchant of record;
/// its License Key API gives us activate / validate / deactivate with an
/// activation limit per key. One activation call at purchase time, then the
/// app never phones home again.
///
/// `organizationID` is empty until the Polar organization exists; until then
/// every call fails fast with `.storefrontNotLive` so the UI stays honest.
struct PolarLicenseClient: LicenseActivating {
    /// Fill in when the Polar org is created (see YAR-95 setup steps).
    static let organizationID = ""

    private let api = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func activate(key: String) async throws -> LicenseRecord {
        guard !Self.organizationID.isEmpty else { throw LicenseError.storefrontNotLive }

        var request = URLRequest(url: api.appendingPathComponent("activate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": key.trimmingCharacters(in: .whitespacesAndNewlines),
            "organization_id": Self.organizationID,
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
        guard !Self.organizationID.isEmpty else { throw LicenseError.storefrontNotLive }

        var request = URLRequest(url: api.appendingPathComponent("deactivate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": record.key,
            "organization_id": Self.organizationID,
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

    /// Maps Polar's activation response onto our local record. The product's
    /// tier travels in the license key's metadata (set when the products are
    /// created in Polar); updates-through is purchase + 12 months for Pro.
    static func record(fromActivation data: Data, key: String) throws -> LicenseRecord {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw LicenseError.invalidKey
        }
        let licenseKey = json["license_key"] as? [String: Any]
        let meta = licenseKey?["metadata"] as? [String: Any]
        let tier: LicenseRecord.Tier = (meta?["tier"] as? String) == "lifetime" ? .lifetime : .pro

        let purchased: Date
        if let created = licenseKey?["created_at"] as? String,
           let date = ISO8601DateFormatter().date(from: created) {
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
}
