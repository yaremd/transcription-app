import Foundation

/// An isolated container for marketing screenshots and manual QA.
///
/// Set `SEAL_DEMO_CONTAINER` to an absolute directory and a **Debug** build
/// keeps its meetings and its entitlement state there instead of in
/// `~/Library/Application Support/Seal`. The real library is neither read nor
/// written, so a demo run cannot rename, migrate, or overwrite a single real
/// meeting.
///
/// The entitlement redirect is the important half. Running the app against a
/// throwaway state file while it still holds the *real* Keychain MAC key is
/// exactly the shape of the 2026-08-12 incident that destroyed the founder's
/// own license: a fresh key made a valid license look tampered, and an eager
/// persist wrote a clean free state over it. So demo mode does what the test
/// host does — an ephemeral key, and a state file somewhere harmless. The
/// Keychain is never touched.
///
/// Release builds compile this to a constant `nil`; there is no way to reach
/// it from a shipped app.
enum DemoMode {

    /// The isolated container, or nil for a normal run.
    static let container: URL? = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["SEAL_DEMO_CONTAINER"]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath,
                      isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Each demo run signs with a fresh ephemeral key, so an entitlement
        // file left by the previous run can never verify against it. That
        // failure path leaves the app running with no window at all, which
        // looks like a hang. Start every run from a blank state file instead.
        try? FileManager.default.removeItem(at: url.appendingPathComponent("entitlement.json"))
        NSLog("DemoMode: isolated container at \(url.path) — the real library is untouched")
        return url
        #else
        return nil
        #endif
    }()

    static var isActive: Bool { container != nil }


    /// A child of the container, created on demand.
    static func directory(_ name: String) -> URL? {
        guard let container else { return nil }
        let url = container.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

