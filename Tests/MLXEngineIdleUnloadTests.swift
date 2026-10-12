import XCTest
@testable import Seal

/// The notes model leaves memory on its own once nothing has used it for a
/// while, and comes back — from disk, not the network — for the next job.
/// Runs against the real model like the engine's other smoke test.
final class MLXEngineIdleUnloadTests: XCTestCase {
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
}
