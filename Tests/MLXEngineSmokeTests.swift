import XCTest
@testable import Seal

/// Runtime smoke test for the on-device notes engine. A green build proves the
/// code compiles; this proves the parts a compiler can't: that the model
/// actually downloads from Hugging Face, that MLX's model factory is registered
/// at runtime, that the tokenizer adapts correctly, and that generation returns
/// real text. Downloads ~1.9 GB on first run (then cached under Application
/// Support), so it can take a few minutes the first time.
final class MLXEngineSmokeTests: XCTestCase {
    func testEmbeddedModelGenerates() async throws {
        try XCTSkipUnless(MLXEngine.isSupported, "MLX requires Apple silicon")

        let reply = try await MLXEngine.shared.generate(
            system: "You are terse. Reply with only what is asked — no extra words or punctuation.",
            user: "Reply with exactly the word: hello",
            maxTokens: 16)

        print("=== MLX SMOKE OUTPUT: '\(reply)' ===")
        XCTAssertFalse(
            reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "on-device model returned an empty response")
    }
}
