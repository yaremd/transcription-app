import Foundation
import CryptoKit

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
    /// The store rejected the request and said why — surface its words.
    case rejected(String)

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
        case .rejected(let message):
            return message
        }
    }
}

/// Everything that identifies OUR storefront on Freemius. One paste fills
/// this in when the store exists (YAR-95): the numeric product ID plus the
/// two checkout links. Tier needs no configuration — it's read from the
/// license's plan name (a plan named "…lifetime…" is the Lifetime tier).
/// None of these are secrets; Freemius's activation endpoints are
/// deliberately public, designed for desktop apps.
enum SealStore {
    static let freemiusProductID = "21938"
    /// Direct checkout links, once the plans exist. Until then the Buy
    /// buttons fall back to the website's pricing section.
    static let checkoutPro: URL? = nil
    static let checkoutLifetime: URL? = nil

    static var isLive: Bool { !freemiusProductID.isEmpty }
}

/// Freemius license activation (YAR-95). Freemius is the merchant of record;
/// its licensing API gives us activate / deactivate with a per-license
/// activation quota. One activation call at purchase time, then the app
/// never phones home again.
///
/// Until `SealStore` is filled in, every call fails fast with
/// `.storefrontNotLive` so the UI stays honest.
struct FreemiusLicenseClient: LicenseActivating {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private var base: URL {
        URL(string: "https://api.freemius.com/v1/products/\(SealStore.freemiusProductID)")!
    }

    func activate(key: String) async throws -> LicenseRecord {
        guard SealStore.isLive else { throw LicenseError.storefrontNotLive }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let (data, response) = try await send(path: "licenses/activate.json", query: [
            "license_key": trimmed,
            "uid": Self.machineUID(),
            "title": Host.current().localizedName ?? "Mac",
        ])
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200, 201:
            return try Self.record(fromActivation: data, key: trimmed)
        case 404:
            throw LicenseError.invalidKey
        case 400...499:
            throw Self.rejection(from: data) ?? .invalidKey
        default:
            throw LicenseError.offline
        }
    }

    func deactivate(_ record: LicenseRecord) async throws {
        guard SealStore.isLive else { throw LicenseError.storefrontNotLive }
        let (data, response) = try await send(path: "licenses/deactivate.json", query: [
            "license_key": record.key,
            "uid": Self.machineUID(),
            "install_id": record.activationID,
        ])
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200...299:
            return
        case 400...499:
            throw Self.rejection(from: data) ?? .invalidKey
        default:
            throw LicenseError.offline
        }
    }

    private func send(path: String, query: [String: String]) async throws -> (Data, URLResponse) {
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        do {
            return try await session.data(for: request)
        } catch {
            throw LicenseError.offline
        }
    }

    // MARK: - Response mapping

    /// Maps Freemius's activation response onto our local record. The
    /// response carries `install_id` (this Mac's activation), the license's
    /// plan name, and license details. Tier: a plan whose name contains
    /// "lifetime" is the Lifetime tier; anything else is Pro — a store
    /// misconfiguration must never brick a paid key, so unknown maps to Pro
    /// with a one-year window from the license's own purchase date.
    /// Parsed tolerantly: field names verified against the live store in the
    /// end-to-end purchase test before launch.
    static func record(fromActivation data: Data, key: String) throws -> LicenseRecord {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LicenseError.invalidKey
        }
        let installID = (json["install_id"] as? NSNumber)?.stringValue
            ?? json["install_id"] as? String
            ?? (json["id"] as? NSNumber)?.stringValue
            ?? json["id"] as? String
        guard let installID else { throw LicenseError.invalidKey }

        let license = json["license"] as? [String: Any]
        let planName = (json["license_plan_name"] as? String
            ?? json["plan_name"] as? String
            ?? license?["plan_name"] as? String ?? "").lowercased()
        let tier: LicenseRecord.Tier = planName.contains("lifetime") ? .lifetime : .pro

        // The license's own creation date is the purchase moment — activation
        // date would wrongly restart the update window on a re-activation
        // years later.
        let created = license?["created"] as? String ?? json["license_created"] as? String
        let purchased = created.flatMap(parseFreemiusDate) ?? Date()

        return LicenseRecord(
            key: key,
            activationID: installID,
            tier: tier,
            purchased: purchased,
            updatesThrough: tier == .lifetime ? nil
                : Calendar.current.date(byAdding: .year, value: 1, to: purchased))
    }

    /// Freemius dates are "Y-m-d H:i:s" in UTC.
    static func parseFreemiusDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }

    /// Pulls the store's own error out of a 4xx body. Freemius errors look
    /// like `{"error": {"code": "invalid_license_key", "message": "…"}}`
    /// (verified against the live API) — the code maps known cases onto our
    /// friendlier copy; anything else surfaces the store's own words.
    static func rejection(from data: Data) -> LicenseError? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String, !message.isEmpty else { return nil }
        let code = (error["code"] as? String ?? "").lowercased()
        if code == "invalid_license_key" { return .invalidKey }
        if code.contains("activation") || message.lowercased().contains("activation")
            || message.lowercased().contains("maximum") {
            return .activationLimitReached
        }
        return .rejected(message)
    }

    // MARK: - Machine identity

    /// Freemius wants a stable 32-character per-machine id so the activation
    /// quota can tell Macs apart. The hardware UUID never leaves the Mac
    /// readable — it's MD5-hashed (as an identifier, not a secret) into
    /// exactly 32 hex characters. Falls back to a random, persisted id if
    /// the hardware UUID is unavailable.
    static func machineUID() -> String {
        let data: Data
        var ts = timespec(tv_sec: 1, tv_nsec: 0)
        var id = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let ok = withUnsafeMutablePointer(to: &id) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: 16) { gethostuuid($0, &ts) == 0 }
        }
        if ok {
            data = withUnsafeBytes(of: id) { Data($0) }
        } else if let stored = UserDefaults.standard.string(forKey: "machineUID"),
                  let storedData = stored.data(using: .utf8) {
            data = storedData
        } else {
            let random = UUID().uuidString
            UserDefaults.standard.set(random, forKey: "machineUID")
            data = Data(random.utf8)
        }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
