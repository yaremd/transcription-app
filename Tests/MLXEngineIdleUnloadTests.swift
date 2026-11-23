import XCTest
import MLX
@testable import Seal

/// The notes model leaves memory on its own once nothing has used it for a
/// while, and comes back — from disk, not the network — for the next job.
/// Runs against the real model like the engine's other smoke test.
final class MLXEngineIdleUnloadTests: XCTestCase {
    /// The point of letting the model go is the memory, so the memory is what
    /// is measured here, not a flag. Until 2026-11-23 the flag test below was
    /// all there was, and it passed while the model's 4 GB — and every
    /// gigabyte a job had worked in and finished with — stayed inside Seal:
    /// MLX keeps freed memory in a reserve of its own, and after four days of
    /// use that reserve had grown to 22 GB.
    ///
    /// The job reads a transcript the size of a half-hour meeting, so the
    /// model's memory of the text grows the way it does for real notes.
    func testAFinishedJobAndAnIdleUnloadGiveTheMemoryBack() async throws {
        try XCTSkipUnless(MLXEngine.isSupported, "MLX requires Apple silicon")
        let engine = MLXEngine.shared
        await engine.setIdleUnloadInterval(2)
        defer { Task { await engine.setIdleUnloadInterval(5 * 60) } }

        let transcript = Self.meetingTranscript(lines: 250)
        let started = Date()
        _ = try await engine.generate(system: "Summarise this meeting in two sentences.",
                                      user: transcript, maxTokens: 96)
        let jobSeconds = Date().timeIntervalSince(started)
        let afterJob = Memory.snapshot()
        let footprintAfterJob = Self.footprint()

        try await Task.sleep(nanoseconds: 4_000_000_000)
        let unloaded = !(await engine.isReady)
        let afterUnload = Memory.snapshot()
        let footprintAfterUnload = Self.footprint()

        print("""
            === MLX MEMORY: job took \(String(format: "%.1f", jobSeconds)) s on \(transcript.count) characters
            === after the job: active \(Self.mb(afterJob.activeMemory)) MB, reserve \(Self.mb(afterJob.cacheMemory)) MB, \
            peak \(Self.mb(afterJob.peakMemory)) MB, process footprint \(Self.mb(footprintAfterJob)) MB
            === after unload:  active \(Self.mb(afterUnload.activeMemory)) MB, reserve \(Self.mb(afterUnload.cacheMemory)) MB, \
            process footprint \(Self.mb(footprintAfterUnload)) MB
            """)

        XCTAssertTrue(unloaded, "two seconds idle should have let the model go")
        XCTAssertLessThan(afterJob.cacheMemory, 300 * Self.megabyte,
                          "a finished job must not leave the memory it worked in behind")
        XCTAssertLessThan(afterUnload.activeMemory + afterUnload.cacheMemory, 200 * Self.megabyte,
                          "letting the model go must hand its memory back to macOS")
    }

    func testTheModelUnloadsWhenIdleAndReloadsForTheNextJob() async throws {
        try XCTSkipUnless(MLXEngine.isSupported, "MLX requires Apple silicon")
        let engine = MLXEngine.shared
        await engine.setIdleUnloadInterval(2)
        defer { Task { await engine.setIdleUnloadInterval(5 * 60) } }

        _ = try await engine.generate(system: "Reply with one word.", user: "Say: ready", maxTokens: 8)
        let loaded = await engine.isReady
        XCTAssertTrue(loaded, "the model should be resident right after a job")

        try await Task.sleep(nanoseconds: 4_000_000_000)
        let stillLoaded = await engine.isReady
        XCTAssertFalse(stillLoaded, "two seconds idle should have freed the model")

        let again = try await engine.generate(system: "Reply with one word.", user: "Say: back", maxTokens: 8)
        XCTAssertFalse(again.isEmpty, "the next job should reload the model from disk and answer")
        let reloaded = await engine.isReady
        XCTAssertTrue(reloaded)
    }

    // MARK: - Helpers

    private static let megabyte = 1024 * 1024
    private static func mb(_ bytes: Int) -> Int { bytes / megabyte }

    /// What macOS charges the process for — the number in Activity Monitor's
    /// Memory column and `top`'s MEM.
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : -1
    }

    /// A made-up meeting in the "[time] Speaker: words" shape the notes prompt
    /// uses, varied enough that the model reads it as text — about 8,000
    /// tokens at 250 lines.
    private static func meetingTranscript(lines count: Int) -> String {
        let speakers = ["You", "Others", "S1", "S2"]
        let subjects = ["the release", "the budget", "onboarding", "the pricing page",
                        "support tickets", "the hiring plan", "the API migration", "the launch post"]
        let verbs = ["needs another review before", "should be finished by", "slipped past",
                     "is blocked until", "can move ahead after", "depends on"]
        let times = ["Monday", "the next sprint", "the board meeting", "the end of the month",
                     "the design sign-off", "Thursday's call"]
        return (0..<count).map { i in
            String(format: "[%02d:%02d] %@: I think %@ %@ %@, and we agreed to check item %d again with %d people.",
                   i / 4, (i % 4) * 15, speakers[i % speakers.count], subjects[i % subjects.count],
                   verbs[(i / 3) % verbs.count], times[(i / 7) % times.count], i + 1, i % 9 + 2)
        }.joined(separator: "\n")
    }
}
