import XCTest
@testable import Seal

/// Where the speech models live, and whether a load can happen offline
/// (YAR-70 / YAR-71).
///
/// Two headline claims ride on this file: "nothing leaves your Mac" (models
/// must not land in an iCloud-synced Documents folder) and "works offline"
/// (a cached model must resolve without a network call). Both used to be
/// false, and both failed silently — which is why they are pinned here.
final class WhisperModelStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// Writes a model folder the way a finished download leaves it.
    @discardableResult
    private func makeVariant(_ variant: String, in base: URL,
                             bundles: [String] = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]) throws -> URL {
        let folder = base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
        for bundle in bundles {
            try writeBundle(bundle, in: folder, complete: true)
        }
        return folder
    }

    /// A UserDefaults the migration can flip without touching the real domain.
    private func scratchDefaults() throws -> UserDefaults {
        let name = "WhisperModelStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - Location

    /// The whole point of YAR-71: never the Documents folder, and the same
    /// root MLXEngine already uses so the two models share one cache.
    func testDownloadBaseIsApplicationSupportNotDocuments() {
        let base = WhisperModelStore.downloadBase
        XCTAssertTrue(base.path.contains("Application Support/Seal/models"),
                      "speech models must share MLXEngine's Application Support root, got \(base.path)")
        XCTAssertFalse(base.path.contains("/Documents/"),
                       "models in ~/Documents get pushed to iCloud Drive — the one place they must never be")
    }

    // MARK: - Cache resolution

    func testCompleteVariantResolvesToItsFolder() throws {
        let expected = try makeVariant("large-v3", in: root)
        let found = WhisperModelStore.cachedFolder(for: "large-v3", base: root)
        XCTAssertEqual(found?.standardizedFileURL, expected.standardizedFileURL)
    }

    func testMissingVariantIsNotCached() {
        XCTAssertNil(WhisperModelStore.cachedFolder(for: "large-v3", base: root),
                     "nothing downloaded yet — WhisperKit must be allowed to fetch")
    }

    /// An interrupted first run must read as "not cached" so the download
    /// resumes. Treating a half-written folder as cached turns a slow first
    /// run into a permanent local-load failure.
    func testPartialDownloadIsNotTreatedAsCached() throws {
        try makeVariant("large-v3", in: root, bundles: ["MelSpectrogram", "AudioEncoder"])   // no TextDecoder
        XCTAssertNil(WhisperModelStore.cachedFolder(for: "large-v3", base: root))
    }

    func testVariantsAreResolvedIndependently() throws {
        try makeVariant("large-v3", in: root)
        XCTAssertNotNil(WhisperModelStore.cachedFolder(for: "large-v3", base: root))
        XCTAssertNil(WhisperModelStore.cachedFolder(for: "large-v3-v20240930_turbo", base: root),
                     "one cached variant must not vouch for another")
    }

    // MARK: - The offline contract

    /// The assertion YAR-70 turns on. `WhisperKit.setupModels` takes its local
    /// branch only when `modelFolder` is non-nil; with it nil it calls
    /// `HubApi.getFilenames`, which has no offline guard and always hits the
    /// network — so a cached model failed to load with Wi-Fi off.
    func testCachedModelYieldsAModelFolderSoTheLoadSkipsTheNetwork() throws {
        let folder = try makeVariant("large-v3", in: root)
        XCTAssertEqual(WhisperModelStore.cachedFolder(for: "large-v3", base: root)?.path, folder.path,
                       "a cached variant must produce the modelFolder that keeps WhisperKit off the network")
    }

    /// And the other half: an absent model must still be downloadable, or the
    /// offline fix would break the first run.
    func testUncachedModelLeavesTheDownloadPathOpen() {
        XCTAssertNil(WhisperModelStore.cachedFolder(for: "small", base: root))
    }

    // MARK: - Migration off ~/Documents

    func testMigrationMovesModelsOutOfDocuments() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        try makeVariant("large-v3", in: legacy)

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: base)

        XCTAssertNotNil(WhisperModelStore.cachedFolder(for: "large-v3", base: base),
                        "the model should now resolve from Application Support")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "an emptied legacy folder should not be left behind in Documents")
    }

    /// mlx-community already lives under the destination. Migrating must merge
    /// into that owner directory, not fail because it exists.
    func testMigrationMergesIntoAnExistingCache() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        try makeVariant("large-v3", in: legacy)
        let notesModel = base.appendingPathComponent("models/mlx-community/Qwen2.5-3B-Instruct-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: notesModel, withIntermediateDirectories: true)

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: base)

        XCTAssertNotNil(WhisperModelStore.cachedFolder(for: "large-v3", base: base))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesModel.path),
                      "the notes model must survive the speech model moving in beside it")
    }

    /// A destination copy wins; the legacy one is never allowed to clobber it.
    func testMigrationDoesNotOverwriteWhatIsAlreadyThere() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        try makeVariant("large-v3", in: legacy)
        let kept = try makeVariant("large-v3", in: base)
        let marker = kept.appendingPathComponent("keep-me")
        try Data().write(to: marker)

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: base)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the already-migrated copy must be the one that survives")
    }

    func testMigrationRunsOnlyOnce() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        let defaults = try scratchDefaults()
        try makeVariant("large-v3", in: legacy)

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: defaults, legacyRoot: legacy, base: base)

        // A second legacy folder appearing later is not our business: the user
        // may have put it there. One sweep, at the upgrade moment, then never
        // touch Documents again.
        try makeVariant("small", in: legacy)
        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: defaults, legacyRoot: legacy, base: base)
        XCTAssertNil(WhisperModelStore.cachedFolder(for: "small", base: base))
    }

    func testMigrationWithNothingToMoveIsHarmless() throws {
        let legacy = root.appendingPathComponent("absent", isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    /// Whatever else is in Documents is the user's. We move our cache and
    /// leave the rest exactly where it was.
    func testMigrationLeavesForeignFilesAlone() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let base = root.appendingPathComponent("base", isDirectory: true)
        try makeVariant("large-v3", in: legacy)
        let stranger = legacy.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: stranger)

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: base)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path),
                      "a non-empty legacy folder must be left in place")
        XCTAssertNotNil(WhisperModelStore.cachedFolder(for: "large-v3", base: base))
    }

    /// Writes one CoreML bundle. `complete: false` reproduces an interrupted
    /// download: the directory and its small descriptors exist, the parameters
    /// do not — measured at 440 KB against 1.2 GB on 2026-08-14.
    private func writeBundle(_ name: String, in folder: URL, complete: Bool) throws {
        let fm = FileManager.default
        let bundle = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("descriptor".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        try Data("model".utf8).write(to: bundle.appendingPathComponent("model.mlmodel"))
        guard complete else { return }
        let weights = bundle.appendingPathComponent("weights", isDirectory: true)
        try fm.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: weights.appendingPathComponent("weight.bin"))
    }

    // MARK: - What an interrupted download actually leaves behind

    /// The bug the field test caught. Every `.mlmodelc` directory is present,
    /// so a plain `fileExists` check calls this cached, hands it to WhisperKit
    /// as a modelFolder, and turns a resumable download into a permanent
    /// local-load failure — the exact outcome the check exists to prevent.
    func testBundleDirectoriesWithoutWeightsAreNotCached() throws {
        let folder = base(named: "partial")
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for bundle in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try writeBundle(bundle, in: folder, complete: false)
        }

        XCTAssertNil(WhisperModelStore.cachedFolder(for: "large-v3", base: base(named: "partial")),
                     "a bundle with no weights/ is a download in flight, not a model")
    }

    /// One unfinished bundle among finished ones is still unfinished.
    func testOneBundleMissingItsWeightsIsEnoughToDisqualify() throws {
        let root = base(named: "mixed")
        let folder = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeBundle("MelSpectrogram", in: folder, complete: true)
        try writeBundle("AudioEncoder", in: folder, complete: true)
        try writeBundle("TextDecoder", in: folder, complete: false)

        XCTAssertNil(WhisperModelStore.cachedFolder(for: "large-v3", base: root))
    }

    /// An empty weights/ directory is not weights either.
    func testEmptyWeightsDirectoryIsNotCached() throws {
        let root = base(named: "empty-weights")
        let folder = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for bundle in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try writeBundle(bundle, in: folder, complete: false)
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(bundle).mlmodelc/weights", isDirectory: true),
                withIntermediateDirectories: true)
        }

        XCTAssertNil(WhisperModelStore.cachedFolder(for: "large-v3", base: root))
    }

    // MARK: - A stranded cache must still migrate

    /// The second bug the field test caught. 54 MB of aborted download at the
    /// destination made `models/argmaxinc/whisperkit-coreml` exist, and a
    /// repo-granular skip would have left the real 9.2 GB in Documents for good.
    func testHalfDownloadedVariantDoesNotStrandTheRealCache() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let dest = root.appendingPathComponent("base", isDirectory: true)
        try makeVariant("large-v3", in: legacy)                       // the real one
        try makeVariant("large-v3-v20240930_turbo", in: legacy)

        // An interrupted download already sitting at the destination.
        let stub = dest.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        for bundle in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try writeBundle(bundle, in: stub, complete: false)
        }

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: dest)

        XCTAssertNotNil(WhisperModelStore.cachedFolder(for: "large-v3", base: dest),
                        "an untouched variant must migrate past a half-written sibling")
        XCTAssertNotNil(WhisperModelStore.cachedFolder(for: "large-v3-v20240930_turbo", base: dest),
                        "and the complete copy must replace the half-written one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "nothing should be left behind in Documents")
    }

    /// The reverse must not happen: a complete model at the destination is
    /// never replaced by anything arriving from the legacy cache.
    func testACompleteDestinationIsNeverDowngraded() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let dest = root.appendingPathComponent("base", isDirectory: true)
        let incoming = try makeVariant("large-v3", in: legacy)
        try writeBundle("AudioEncoder", in: incoming, complete: false)   // legacy copy is broken
        let kept = try makeVariant("large-v3", in: dest)
        try Data("keep".utf8).write(to: kept.appendingPathComponent("marker"))

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent("marker").path),
                      "the complete destination copy must survive")
    }

    private func base(named name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// The third thing the field test caught. HubApi keeps its download
    /// bookkeeping in a hidden `.cache` directory; skipping hidden entries
    /// orphaned it *and* left `~/Documents/huggingface` standing, because the
    /// prune then found it non-empty. 9 GB moved and the folder still there is
    /// a failure at the only part the user sees.
    func testHiddenCacheMovesSoTheFolderCanActuallyGo() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let dest = root.appendingPathComponent("base", isDirectory: true)
        try makeVariant("large-v3", in: legacy)
        let cache = legacy.appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("bookkeeping".utf8).write(to: cache.appendingPathComponent("etag"))

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: dest)

        let movedCache = dest.appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/etag")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedCache.path),
                      "the download bookkeeping belongs with the models it describes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "with nothing left, the folder in Documents must go")
    }

    /// Merging into an existing destination leaves the source directories
    /// behind once their children have gone. Any one of them surviving keeps
    /// everything above it non-empty, so the folder in Documents outlives the
    /// models — emptied, pointless, and still there. Seen as a leftover
    /// `.cache/huggingface/download` during the 2026-08-14 field pass.
    func testEmptiedSourceDirectoriesArePrunedAtEveryDepth() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let dest = root.appendingPathComponent("base", isDirectory: true)
        let fm = FileManager.default

        // A destination that already holds the repo, so the move must merge
        // child-by-child rather than take the wholesale fast path.
        try makeVariant("large-v3", in: dest)

        let repo = "models/argmaxinc/whisperkit-coreml"
        let nested = legacy.appendingPathComponent("\(repo)/.cache/huggingface/download", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("etag".utf8).write(to: nested.appendingPathComponent("in-flight"))
        try makeVariant("large-v3-v20240930_turbo", in: legacy)

        WhisperModelStore.migrateLegacyCacheIfNeeded(defaults: try scratchDefaults(),
                                                     legacyRoot: legacy, base: dest)

        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("\(repo)/.cache/huggingface/download/in-flight").path),
                      "the nested bookkeeping still has to arrive")
        XCTAssertFalse(fm.fileExists(atPath: legacy.path),
                       "and nothing empty may be left holding the folder open")
    }
}
