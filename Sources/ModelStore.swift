import Foundation
import OSLog

/// The one place that decides *where* downloaded model weights live and whether
/// a variant is already on disk.
///
/// Two bugs came from not having this. Both engines fetch from Hugging Face, but
/// only `MLXEngine` ever passed a `downloadBase`, so WhisperKit fell back to
/// `HubApi`'s default — the user's **Documents** folder — and quietly parked
/// several GB of weights somewhere iCloud Drive syncs (YAR-71). And because
/// `Transcriber` passed no `modelFolder` either, `WhisperKit.setupModels` took
/// its download branch on *every* load, calling the Hub API even when the model
/// was already cached — which made ⌘N fail outright with the network off,
/// against a landing page that promises offline support (YAR-70).
///
/// So: one root under Application Support, shared by both engines, and a
/// local-first lookup that lets WhisperKit skip the network when it can.
enum ModelStore {
    private static let log = Logger(subsystem: "com.yarem.Seal", category: "ModelStore")

    /// The Hugging Face cache root for every model the app downloads.
    /// `HubApi` appends `models/<repo>` beneath this, so Whisper and the MLX
    /// notes model end up as siblings:
    ///
    ///     Seal/models/models/argmaxinc/whisperkit-coreml/…
    ///     Seal/models/models/mlx-community/…
    static let hubBase: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("Seal/models", isDirectory: true)
    }()

    static let whisperRepo = "argmaxinc/whisperkit-coreml"

    /// Where WhisperKit variants land: `<hubBase>/models/<repo>`.
    static var whisperRepoDirectory: URL {
        hubBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(whisperRepo, isDirectory: true)
    }

    /// The Core ML bundles `WhisperKit.loadModels` needs before a variant folder
    /// is usable. An interrupted download leaves the folder present but short a
    /// bundle, and handing that to WhisperKit as a `modelFolder` turns a
    /// resumable download into a confusing local-load failure — so a variant
    /// only counts as cached when all three are there.
    private static let requiredBundles = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    /// The on-disk folder for a fully downloaded Whisper variant, or nil when it
    /// isn't cached (or is only partly cached). Callers pass the result as
    /// `WhisperKitConfig.modelFolder` so `setupModels` takes its local branch.
    static func cachedWhisperFolder(variant: String) -> URL? {
        prepare()
        let folder = whisperRepoDirectory
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
        guard isCompleteWhisperVariant(at: folder) else {
            log.notice("Whisper variant \(variant, privacy: .public) is absent or incomplete on disk — will download")
            return nil
        }
        return folder
    }

    /// True when `folder` holds every Core ML bundle WhisperKit needs. Split out
    /// from `cachedWhisperFolder` so it can be tested against a temp directory
    /// without touching the real cache.
    static func isCompleteWhisperVariant(at folder: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return requiredBundles.allSatisfy { bundle in
            var bundleIsDir: ObjCBool = false
            let path = folder.appendingPathComponent(bundle, isDirectory: true).path
            return fm.fileExists(atPath: path, isDirectory: &bundleIsDir) && bundleIsDir.boolValue
        }
    }

    // MARK: - Legacy cache migration

    /// Runs the Documents→Application Support migration exactly once per launch.
    /// `static let` gives us lazy, thread-safe, run-once semantics for free.
    private static let prepared: Void = {
        migrateLegacyDocumentsCache()
    }()

    /// Idempotent; cheap after the first call. Called at app startup and again
    /// from every lookup, so no model load can outrun it.
    static func prepare() { _ = prepared }

    /// WhisperKit's old default was `~/Documents/huggingface`. Without this,
    /// every existing user silently re-downloads several GB after the fix — and
    /// the original copy stays in Documents, still syncing to iCloud, which is
    /// the actual complaint.
    ///
    /// Moves the two repo trees WhisperKit puts there (`argmaxinc` for the
    /// weights, `openai` for the tokenizer) and cleans up behind itself. Any
    /// failure is survivable: we log and leave the legacy copy alone, and the
    /// worst case is a re-download.
    private static func migrateLegacyDocumentsCache() {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let legacyRoot = documents.appendingPathComponent("huggingface", isDirectory: true)
        guard fm.fileExists(atPath: legacyRoot.path) else { return }

        let legacyModels = legacyRoot.appendingPathComponent("models", isDirectory: true)
        let newModels = hubBase.appendingPathComponent("models", isDirectory: true)

        for owner in ["argmaxinc", "openai"] {
            let source = legacyModels.appendingPathComponent(owner, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = newModels.appendingPathComponent(owner, isDirectory: true)

            do {
                if fm.fileExists(atPath: destination.path) {
                    // Already migrated (or re-downloaded) on a previous launch.
                    // The legacy tree is our own cache and now redundant, so
                    // remove it — that's the whole point of the migration. Only
                    // after the new copy is verified, never on faith.
                    if isUsableTree(destination, requiringBundles: owner == "argmaxinc") {
                        try fm.removeItem(at: source)
                        log.notice("Removed the redundant legacy \(owner, privacy: .public) cache from Documents")
                    } else {
                        log.notice("Kept the legacy \(owner, privacy: .public) cache — the copy in Application Support looks incomplete")
                    }
                    continue
                }
                try fm.createDirectory(at: newModels, withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: destination)
                log.notice("Moved the \(owner, privacy: .public) model cache out of Documents")
            } catch {
                // Cross-volume move, permissions, iCloud eviction — all mean
                // "leave it, re-download later", never "fail to start".
                log.error("Could not migrate the \(owner, privacy: .public) model cache: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Only remove the legacy root once it's genuinely empty — it belongs to
        // the user's Documents folder, so we never delete anything we didn't
        // just account for.
        removeIfEmpty(legacyModels)
        removeIfEmpty(legacyRoot)
    }

    /// Is the copy at the new location substantial enough that deleting the
    /// legacy duplicate is safe? For the weights (`argmaxinc`) that means at
    /// least one variant with every Core ML bundle present. The tokenizer repo
    /// (`openai`) has no bundles, so a non-empty repo folder is all there is to
    /// check. Anything less and we keep the legacy copy — a stale folder in
    /// Documents is a far better outcome than a deleted cache and a broken app.
    private static func isUsableTree(_ owner: URL, requiringBundles: Bool) -> Bool {
        let fm = FileManager.default
        guard let repos = try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil),
              !repos.isEmpty else { return false }

        guard requiringBundles else {
            return repos.contains { repo in
                (try? fm.contentsOfDirectory(atPath: repo.path))?.isEmpty == false
            }
        }

        return repos.contains { repo in
            guard let variants = try? fm.contentsOfDirectory(at: repo, includingPropertiesForKeys: nil) else {
                return false
            }
            return variants.contains { isCompleteWhisperVariant(at: $0) }
        }
    }

    private static func removeIfEmpty(_ directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty else { return }
        try? fm.removeItem(at: directory)
    }
}
