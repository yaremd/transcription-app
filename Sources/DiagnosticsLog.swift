import Foundation
import OSLog

/// A per-meeting record of every transcription decision, written next to the
/// meeting's audio as `<id>.diag.log`.
///
/// The decode trail already existed — `Transcriber` emits a line for every
/// candidate, score and drop — but production discarded it, so a session that
/// went wrong could only be diagnosed by replaying its audio offline. That
/// works when the failure reproduces. The 2026-07-31 English lesson did not:
/// the same audio through the same build transcribed cleanly, twice, while the
/// live session had locked its mic stream into Ukrainian and deleted 98 real
/// English lines. Nothing on disk said why. This is what says why.
///
/// Local only — the file sits beside the `.m4a` pair and never leaves the Mac,
/// so a bug report is "send me the three files next to that meeting".
///
/// Writes are appended on a background queue (never blocking a decode or the
/// audio path) and stop at `byteLimit`, so a long meeting cannot fill the disk.
final class DiagnosticsLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yarem.Seal.diagnostics", qos: .utility)
    private let url: URL
    private let byteLimit: Int
    private let started = Date()
    private var handle: FileHandle?
    private var written = 0
    private var truncated = false
    private let log = Logger(subsystem: "com.yarem.Seal", category: "Diagnostics")

    /// `byteLimit` caps the file. 8 MB holds a very long meeting's trail; past
    /// it the log stops with a final note rather than growing without bound.
    init(url: URL, byteLimit: Int = 8 * 1024 * 1024) {
        self.url = url
        self.byteLimit = byteLimit
        queue.async { [self] in
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                log.error("could not create \(url.lastPathComponent, privacy: .public)")
                return
            }
            handle = try? FileHandle(forWritingTo: url)
        }
    }

    /// Appends one line, stamped with seconds since the recording started —
    /// the clock that matters when the question is "why did this stream go
    /// quiet for eight minutes?".
    func write(_ line: String) {
        let stamp = Date().timeIntervalSince(started)
        queue.async { [self] in
            guard let handle, !truncated else { return }
            let text = String(format: "%8.2f %@\n", stamp, line)
            guard let data = text.data(using: .utf8) else { return }
            if written + data.count > byteLimit {
                truncated = true
                let note = "         --- diagnostics truncated at \(byteLimit) bytes ---\n"
                try? handle.write(contentsOf: Data(note.utf8))
                try? handle.close()
                self.handle = nil
                return
            }
            written += data.count
            try? handle.write(contentsOf: data)
        }
    }

    /// Flushes and closes. Safe to call more than once.
    func close() {
        queue.async { [self] in
            try? handle?.close()
            handle = nil
        }
    }
}
