import XCTest
import WhisperKit
@testable import Seal

/// The empirical half of YAR-70: prove a cached model actually loads with the
/// network unavailable.
///
/// `WhisperModelStoreTests` pins the path logic; this loads a real Whisper
/// model through real WhisperKit with the Hugging Face endpoint pointed at a
/// closed port. If any part of the load still reaches for the network — the
/// model resolution, or the tokenizer, which YAR-70 called out as "the second
/// thing to break" — this test cannot pass.
///
/// Skips when the small model is not cached on this machine, so a fresh
/// checkout does not fail on a several-hundred-megabyte prerequisite.
final class OfflineModelLoadTests: XCTestCase {

    /// Nothing listens here, and it is not routable off-box: any real request
    /// fails rather than quietly succeeding on a good connection. That is what
    /// makes a passing load meaningful.
    private let deadEndpoint = "http://127.0.0.1:9"

    private let variant = "base.en"     // the smallest cached variant, ~140 MB

    /// Finds `variant` in either cache root — this test has to work both before
    /// and after the migration off ~/Documents.
    private func locateCachedModel() -> (base: URL, folder: URL)? {
        let fm = FileManager.default
        let candidates = [
            WhisperModelStore.downloadBase,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("huggingface", isDirectory: true),
        ]
        for base in candidates {
            if let folder = WhisperModelStore.cachedFolder(for: variant, base: base) {
                return (base, folder)
            }
        }
        return nil
    }

    func testCachedModelLoadsWithNoNetwork() async throws {
        guard let (base, folder) = locateCachedModel() else {
            throw XCTSkip("\(variant) isn't cached on this machine — run the app once to download it")
        }

        var config = WhisperModelStore.config(model: variant, prewarm: false, base: base)
        XCTAssertEqual(config.modelFolder, folder.path,
                       "the cached model must be handed to WhisperKit as a modelFolder")
        // Everything below this line would have hit huggingface.co before the fix.
        config.modelEndpoint = deadEndpoint

        let kit = try await WhisperKit(config)
        // `config` sets load: false, so this is the real load — and the one
        // that pulls in the tokenizer.
        try await kit.loadModels()

        XCTAssertNotNil(kit.tokenizer, "the tokenizer must resolve from the local cache too")
        XCTAssertEqual(kit.modelState, .loaded)
    }

    /// The control, and the regression guard: the config this app used before
    /// the fix — no `modelFolder` — cannot load the very same cached model
    /// offline. `WhisperKit.setupModels` takes its download branch whenever
    /// `modelFolder` is nil, and `HubApi.getFilenames` has no offline guard.
    ///
    /// Without this test the one above could pass for the wrong reason (a
    /// machine that happens to be online, an endpoint that is never consulted),
    /// and nothing would notice if someone dropped the `modelFolder` again.
    func testConfigWithoutAModelFolderCannotLoadOffline() async throws {
        guard locateCachedModel() != nil else {
            throw XCTSkip("\(variant) isn't cached on this machine — run the app once to download it")
        }

        let config = WhisperKitConfig(model: variant, prewarm: false)   // the pre-fix construction
        config.modelEndpoint = deadEndpoint

        do {
            _ = try await WhisperKit(config)
            XCTFail("this is the YAR-70 bug: without a modelFolder the load must reach for the network")
        } catch {
            // Expected — and exactly why `WhisperModelStore.config` exists.
        }
    }

    /// The counterpart: with no cached model there is nothing to load offline,
    /// and WhisperKit must be left free to download. Pointing it at a dead
    /// endpoint proves the download path is the one being taken.
    func testUncachedModelStillAttemptsADownload() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineModelLoadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var config = WhisperModelStore.config(model: variant, prewarm: false, base: scratch)
        XCTAssertNil(config.modelFolder, "an empty cache must not claim to hold a model")
        config.modelEndpoint = deadEndpoint

        do {
            _ = try await WhisperKit(config)
            XCTFail("with nothing cached and no network, the load should fail rather than pretend")
        } catch {
            // Expected: the download branch ran and could not reach the endpoint.
        }
    }
}
