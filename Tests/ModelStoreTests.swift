import XCTest
@testable import Seal

/// Guards the two rules behind YAR-70 and YAR-71: model weights belong under
/// Application Support (never the user's iCloud-synced Documents folder), and a
/// half-downloaded variant must not be treated as cached — handing WhisperKit an
/// incomplete `modelFolder` turns a resumable download into a load failure.
final class ModelStoreTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Where the weights live

    func testHubBaseIsUnderApplicationSupportNotDocuments() {
        let path = ModelStore.hubBase.path
        XCTAssertTrue(path.contains("Application Support"),
                      "model weights must live under Application Support, got \(path)")
        XCTAssertFalse(path.contains("/Documents"),
                       "model weights must never land in Documents — that folder syncs to iCloud")
    }

    /// The layout `cachedWhisperFolder` assumes has to match what `HubApi`
    /// actually writes: `<downloadBase>/models/<repo>`.
    func testWhisperRepoDirectorySitsBeneathTheSharedHubRoot() {
        // Compare `path`, not the URLs — the implementation builds a directory
        // URL (trailing slash) and this one doesn't.
        let expected = ModelStore.hubBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml").path
        XCTAssertEqual(ModelStore.whisperRepoDirectory.path, expected)
    }

    // MARK: - Partial-download guard

    func testCompleteVariantIsAccepted() throws {
        let folder = try makeVariant(bundles: [
            "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
        ])
        XCTAssertTrue(ModelStore.isCompleteWhisperVariant(at: folder))
    }

    func testVariantMissingABundleIsRejected() throws {
        // Exactly what an interrupted download leaves behind.
        let folder = try makeVariant(bundles: ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"])
        XCTAssertFalse(ModelStore.isCompleteWhisperVariant(at: folder),
                       "a variant missing TextDecoder.mlmodelc must re-download, not load locally")
    }

    func testEmptyVariantFolderIsRejected() throws {
        let folder = try makeVariant(bundles: [])
        XCTAssertFalse(ModelStore.isCompleteWhisperVariant(at: folder))
    }

    func testAbsentVariantFolderIsRejected() {
        let folder = scratch.appendingPathComponent("openai_whisper-nope", isDirectory: true)
        XCTAssertFalse(ModelStore.isCompleteWhisperVariant(at: folder))
    }

    /// A file named like a bundle is not a bundle — the check is directory-aware
    /// so a truncated download can't masquerade as a complete one.
    func testFileStandingInForABundleIsRejected() throws {
        let folder = try makeVariant(bundles: ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"])
        let decoy = folder.appendingPathComponent("TextDecoder.mlmodelc")
        try Data().write(to: decoy)
        XCTAssertFalse(ModelStore.isCompleteWhisperVariant(at: folder))
    }

    // MARK: - Helpers

    private func makeVariant(bundles: [String]) throws -> URL {
        let folder = scratch.appendingPathComponent("openai_whisper-large-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for bundle in bundles {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(bundle, isDirectory: true),
                withIntermediateDirectories: true)
        }
        return folder
    }
}
