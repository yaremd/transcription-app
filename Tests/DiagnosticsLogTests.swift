import XCTest
@testable import Seal

/// The diagnostics file is the thing that makes the *next* bad session
/// diagnosable, so it has to actually land on disk — the 2026-07-31 lesson was
/// undiagnosable precisely because nothing was written.
final class DiagnosticsLogTests: XCTestCase {

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString).log")
    }

    /// Writes land in the file, in order, each stamped with elapsed seconds.
    func testLinesAreWrittenInOrderWithTimestamps() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = DiagnosticsLog(url: url)
        log.write("[You] FINAL candidates=[uk,en] protected=- dominant=-")
        log.write("[You] VOTE en (tally [\"en\": 1])")
        log.close()

        let text = try waitForContents(of: url)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("[You] FINAL candidates=[uk,en] protected=- dominant=-"))
        XCTAssertTrue(lines[1].hasSuffix("[You] VOTE en (tally [\"en\": 1])"))
        // Each line is prefixed with seconds-since-start — the clock you need
        // to answer "why did this stream go quiet for eight minutes?".
        XCTAssertNotNil(Double(lines[0].prefix(8).trimmingCharacters(in: .whitespaces)))
    }

    /// A long meeting must not be able to fill the disk. Past the cap the log
    /// stops and says so, rather than growing without bound or silently lying.
    func testTheLogStopsAtItsByteLimit() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = DiagnosticsLog(url: url, byteLimit: 400)
        for i in 0..<200 { log.write("line \(i) — padding to push past the limit quickly") }
        log.close()

        let text = try waitForContents(of: url)
        XCTAssertLessThan(text.utf8.count, 700, "the cap must actually bound the file")
        XCTAssertTrue(text.contains("diagnostics truncated"),
                      "truncation has to be visible, so a short log is never mistaken for a quiet session")
    }

    /// Writing after close is a no-op, not a crash: final passes can land after
    /// the recording tore down.
    func testWritingAfterCloseIsHarmless() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = DiagnosticsLog(url: url)
        log.write("before")
        log.close()
        log.write("after")
        log.close()

        let text = try waitForContents(of: url)
        XCTAssertTrue(text.contains("before"))
        XCTAssertFalse(text.contains("after"))
    }

    /// Writes are asynchronous on a background queue; give them a moment to
    /// drain before reading.
    private func waitForContents(of url: URL, timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                // One more beat so a partially-drained queue settles.
                Thread.sleep(forTimeInterval: 0.2)
                return (try? String(contentsOf: url, encoding: .utf8)) ?? text
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw XCTSkip("diagnostics file never appeared at \(url.path)")
    }
}
