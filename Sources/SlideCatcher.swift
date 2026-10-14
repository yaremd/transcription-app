import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Catches what is shared in a call on its own, so nobody has to remember to
/// press Snap. While a recording runs it glances at the call's window — only
/// that window: a call app's, or a browser window titled like a meeting, never
/// the rest of the screen — every second and a half, as a thumbnail it keeps
/// only long enough to compare with the last one. When the picture changes and
/// then holds still for about three seconds (a new slide, the next page), it
/// takes the full capture and reads it. The frame is kept only if it brings new
/// text that reads like content — a few words to a line, not a grid of names
/// under video tiles — so faces moving in a call never count, and a slide shown
/// twice is kept once. At most one every 20 seconds; nothing leaves the Mac.
actor SlideCatcher {
    struct Catch {
        let image: CGImage
        /// The shared content's text, the call app's own bars left out.
        let text: String
        let sourceApp: String?
        let at: Date
    }

    static let interval: TimeInterval = 1.5
    /// Reading a picture is the costly part: not more often than this.
    static let readInterval: TimeInterval = 8
    static let cooldown: TimeInterval = 20
    static let perMeeting = 150

    private var loop: Task<Void, Never>?
    private var window: CGWindowID?
    private var watch = SettleWatch()
    /// The words of the last few frames kept, to tell a new slide from one
    /// shown again.
    private var recent: [Set<String>] = []
    private var lastRead: Date?
    private var lastKept: Date?
    private var kept = 0

    /// Watches until `stop()`. `watching` is asked before every glance (a
    /// recording is running, not paused, and the setting is on); `keep` files
    /// what is caught.
    func start(watching: @escaping @MainActor () -> Bool,
               keep: @escaping @MainActor (Catch) -> Void) {
        loop?.cancel()
        window = nil
        watch = SettleWatch()
        recent = []
        lastRead = nil
        lastKept = nil
        kept = 0
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if await watching() {
                    await self.glance(keep: keep)
                } else {
                    await self.rest()
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// A snap by hand counts as caught: the same slide isn't caught again.
    func noteSnapped(text: String) {
        remember(Self.words(in: text))
    }

    private func rest() {
        watch.pause()
    }

    private func glance(keep: @MainActor (Catch) -> Void) async {
        guard kept < Self.perMeeting, CGPreflightScreenCaptureAccess(),
              let target = await Self.callWindow() else { rest(); return }
        if target.window.windowID != window {
            window = target.window.windowID
            watch = SettleWatch()
        }
        guard let thumbnail = try? await Self.capture(target.window, width: 320),
              watch.observe(Thumbprint(thumbnail)) else { return }
        let now = Date()
        if let lastRead, now.timeIntervalSince(lastRead) < Self.readInterval { return }
        if let lastKept, now.timeIntervalSince(lastKept) < Self.cooldown { return }
        watch.markRead()
        lastRead = now
        guard let image = try? await Self.capture(target.window, width: nil),
              let lines = try? await ScreenTextReader.lines(in: image) else { return }
        let content = Self.contentLines(lines)
        guard Self.isWorthKeeping(content, after: recent) else { return }
        remember(Set(content.flatMap { Self.words(in: $0) }))
        lastKept = Date()
        kept += 1
        await keep(Catch(image: image, text: content.joined(separator: "\n"),
                         sourceApp: target.app, at: Date()))
    }

    private func remember(_ words: Set<String>) {
        guard !words.isEmpty else { return }
        recent.append(words)
        if recent.count > 3 { recent.removeFirst() }
    }

    // MARK: - What counts

    /// The lines that are the shared content rather than the call app's own
    /// bars: the strips along the bottom (controls, the meeting code, the
    /// time) and the top (the title) are left out. Vision's boxes are
    /// normalized with the origin at the bottom left.
    static func contentLines(_ lines: [ScreenTextReader.ReadLine]) -> [String] {
        lines.filter { $0.box.midY > 0.12 && $0.box.midY < 0.92 }.map(\.text)
    }

    /// Whether a settled picture's text is a new slide: it reads like content
    /// (two lines of three words or more, or one of five — not name labels
    /// under video tiles) and at least a third of its words weren't in any of
    /// the last few frames kept.
    static func isWorthKeeping(_ lines: [String], after recent: [Set<String>]) -> Bool {
        let counts = lines.map { words(in: $0, minimumLength: 1).count }
        guard counts.filter({ $0 >= 3 }).count >= 2 || counts.contains(where: { $0 >= 5 }) else { return false }
        let all = Set(lines.flatMap { words(in: $0) })
        guard all.count >= 6 else { return false }
        return recent.allSatisfy { before in
            Double(all.subtracting(before).count) / Double(all.count) >= 0.35
        }
    }

    /// Lowercased words of at least `minimumLength` letters (four by default,
    /// which leaves most "the"s and "and"s out of the comparison).
    static func words(in text: String, minimumLength: Int = 4) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= minimumLength })
    }

    /// Whether a browser window's title says a meeting is in it: Google Meet
    /// ("Meet – abc-defg-hij"), Teams, Zoom's web client, Webex, Whereby,
    /// Jitsi. Any other browser window is left alone.
    static func looksLikeMeeting(_ title: String) -> Bool {
        let t = title.lowercased()
        let names = ["google meet", "meet.google.com", "microsoft teams", "teams meeting", "zoom meeting",
                     "zoom workplace", "app.zoom.us", "webex", "whereby", "jitsi"]
        if names.contains(where: t.contains) { return true }
        if t.hasPrefix("meet – ") || t.hasPrefix("meet - ") || t.hasPrefix("meet — ") { return true }
        // A Meet code on its own: three letters, four, three.
        return t.range(of: #"(^|[^a-z])[a-z]{3}-[a-z]{4}-[a-z]{3}([^a-z]|$)"#, options: .regularExpression) != nil
    }

    // MARK: - Capturing

    /// The call's window: a call app's biggest window on screen, or a browser
    /// window whose title says it holds a meeting. Never Seal's own.
    static func callWindow() async -> (window: SCWindow, app: String)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return nil
        }
        let me = Bundle.main.bundleIdentifier ?? ""
        let candidates = content.windows.compactMap { window -> (SCWindow, String)? in
            guard let owner = window.owningApplication, owner.bundleIdentifier != me,
                  let app = CallAppDirectory.match(owner.bundleIdentifier),
                  window.isOnScreen, window.windowLayer == 0,
                  window.frame.width >= 400, window.frame.height >= 300 else { return nil }
            if app.isBrowser, !looksLikeMeeting(window.title ?? "") { return nil }
            return (window, app.name)
        }
        guard let best = candidates.max(by: { $0.0.frame.width * $0.0.frame.height < $1.0.frame.width * $1.0.frame.height })
        else { return nil }
        return (best.0, best.1)
    }

    /// The window alone, `width` points wide (its full resolution when nil).
    static func capture(_ window: SCWindow, width: CGFloat?) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let size = window.frame.size
        let w = width ?? size.width * scale
        configuration.width = max(1, Int(w))
        configuration.height = max(1, Int(w * size.height / max(size.width, 1)))
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    }
}

/// A picture reduced to 64 × 36 shades of grey: enough to tell a new slide
/// from the same one, and a mouse moving from nothing at all.
struct Thumbprint: Equatable {
    static let columns = 64
    static let rows = 36
    /// How far a cell's shade must move to count as changed.
    static let shade = 16
    let cells: [UInt8]

    init(cells: [UInt8]) { self.cells = cells }

    init(_ image: CGImage) {
        let w = Self.columns, h = Self.rows
        var buffer = [UInt8](repeating: 0, count: w * h)
        buffer.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        cells = buffer
    }

    /// The share of cells that changed, among those not `ignoring`.
    func changed(from other: Thumbprint, ignoring busy: [Bool] = []) -> Double {
        guard cells.count == other.cells.count, !cells.isEmpty else { return 1 }
        var counted = 0, moved = 0
        for i in cells.indices where busy.isEmpty || !busy[i] {
            counted += 1
            if abs(Int(cells[i]) - Int(other.cells[i])) > Self.shade { moved += 1 }
        }
        return counted == 0 ? 0 : Double(moved) / Double(counted)
    }
}

/// Tells, glance by glance, when the call's window has settled on a picture
/// not yet read. Cells that keep changing — video tiles — are learned and left
/// out, so a talking face beside a slide neither keeps the slide from holding
/// still nor counts as a change itself; a slide's cells change once and settle.
struct SettleWatch {
    /// Glances that must look the same after a change: about three seconds.
    static let stillGlances = 2
    /// The share of the steady cells that must change to be a change.
    static let changeShare = 0.03

    private var last: Thumbprint?
    /// Per cell: how often it has changed lately, rising by one per change and
    /// falling by one per quiet glance. Two and up is a video tile.
    private var motion: [UInt8] = []
    private var still = 0
    private var dirty = true
    private var read: Thumbprint?

    /// Takes the next glance; true when the picture has held still long
    /// enough and is not the one last read.
    mutating func observe(_ print: Thumbprint) -> Bool {
        defer { self.last = print }
        guard let last, last.cells.count == print.cells.count else {
            motion = Array(repeating: 0, count: print.cells.count)
            still = 0
            dirty = true
            return false
        }
        let busy = motion.map { $0 >= 2 }
        var steady = 0, moved = 0
        for i in print.cells.indices {
            let changed = abs(Int(print.cells[i]) - Int(last.cells[i])) > Thumbprint.shade
            if !busy[i] {
                steady += 1
                if changed { moved += 1 }
            }
            motion[i] = changed ? min(motion[i] + 1, 6) : (motion[i] > 0 ? motion[i] - 1 : 0)
        }
        // Mostly video, nothing to settle on.
        guard steady * 10 >= print.cells.count * 3 else {
            still = 0
            return false
        }
        if Double(moved) / Double(steady) >= Self.changeShare {
            still = 0
            dirty = true
            return false
        }
        still += 1
        guard still >= Self.stillGlances, dirty else { return false }
        // Settled back on the picture already read (a face moved, then stopped).
        if let read, print.changed(from: read, ignoring: busy) < 0.02 {
            dirty = false
            return false
        }
        return true
    }

    /// The settled picture is being read: wait for the next change.
    mutating func markRead() {
        dirty = false
        read = last
    }

    /// Not watching for a while (paused): start the stillness count over.
    mutating func pause() {
        last = nil
        still = 0
    }
}
