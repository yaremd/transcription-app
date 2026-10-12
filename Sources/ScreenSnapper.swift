import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Captures what the user is looking at, once, on demand: the call app's
/// window when one is on screen, otherwise the display — never Seal's own
/// windows, which are left out of the picture so a capture made from the
/// recording page shows what is behind it. Nothing is captured without a
/// click or a shortcut, and nothing streams.
enum ScreenSnapper {
    struct SnapError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Snapshot {
        let image: CGImage
        /// The call app whose window this is ("Zoom"), nil for the display.
        let sourceApp: String?
    }

    /// Whether macOS lets Seal capture the screen. Asking shows the system
    /// dialog the first time; a refusal lands in System Settings.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func capture() async throws -> Snapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = Bundle.main.bundleIdentifier ?? ""
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        // A call app's biggest window on screen is almost always the call —
        // and what is shared into it.
        let callWindow = content.windows
            .filter { window in
                guard let app = window.owningApplication, app.bundleIdentifier != me,
                      CallAppDirectory.match(app.bundleIdentifier) != nil,
                      window.isOnScreen, window.windowLayer == 0,
                      window.frame.width >= 400, window.frame.height >= 300 else { return false }
                return true
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let filter: SCContentFilter
        let sourceApp: String?
        if let window = callWindow {
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceApp = CallAppDirectory.match(window.owningApplication?.bundleIdentifier ?? "")?.name
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                throw SnapError(message: "No display to capture.")
            }
            let seal = content.applications.filter { $0.bundleIdentifier == me }
            filter = SCContentFilter(display: display, excludingApplications: seal, exceptingWindows: [])
            sourceApp = nil
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return Snapshot(image: image, sourceApp: sourceApp)
    }
}
