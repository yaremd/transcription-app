import Foundation
import os
import WhisperKit

/// Where the speech models live, and whether they are already on this Mac.
///
/// Both jobs used to be left to WhisperKit's defaults, and both defaults were
/// wrong for this app:
///
/// 1. **Location.** `WhisperKitConfig` with no `downloadBase` lets `HubApi`
///    fall back to its own default — the user's *Documents* folder. So the app
///    whose entire pitch is "nothing leaves your Mac" quietly wrote 9.2 GB of
///    model weights into exactly the directory iCloud Drive's Desktop &
///    Documents sync uploads. `MLXEngine.makeHubApi()` already knew better;
///    this puts the speech models under the same Application Support root, so
///    the two share one Hugging Face cache instead of keeping rival copies.
///
/// 2. **Offline.** `WhisperKit.setupModels` only takes its local branch when a
///    `modelFolder` is handed to it — with `modelFolder` nil it takes the
///    *download* branch no matter what is already cached, and that calls
///    `HubApi.getFilenames`, which unlike `HubApi.snapshot` has no offline
///    guard and unconditionally GETs huggingface.co. A fully downloaded model
///    therefore failed to load with Wi-Fi off, and "works offline" was false.
///    Resolving the cached variant ourselves and passing it as `modelFolder`
///    skips the network entirely.
///
/// The two fixes belong together: knowing where models live is what makes it
/// possible to tell whether they are already here.
enum WhisperModelStore {
    private static let log = Logger(subsystem: "com.yarem.Seal", category: "WhisperModelStore")

    /// The Hugging Face cache root, shared with `MLXEngine.makeHubApi()`.
    /// `HubApi` appends `models/<owner>/<repo>` beneath it.
    static var downloadBase: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Seal/models", isDirectory: true)
    }

    /// WhisperKit's default repo, and the folder-name convention inside it:
    /// variant `large-v3` lands in `openai_whisper-large-v3`.
    private static let modelRepoPath = "models/argmaxinc/whisperkit-coreml"
    private static func variantFolderName(_ variant: String) -> String { "openai_whisper-\(variant)" }

    /// The CoreML bundles `WhisperKit.loadModels` insists on before it will
    /// load a folder. Checking the same three here is what stops a half-finished
    /// download from being mistaken for a cached model — otherwise an
    /// interrupted first run turns into a permanent "local load failed" instead
    /// of a resumable download.
    private static let requiredBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    /// The on-disk folder for `variant`, but only when it holds a complete
    /// model. Nil means "not here, or not finished" — let WhisperKit download.
    static func cachedFolder(for variant: String, base: URL? = nil) -> URL? {
        let folder = (base ?? downloadBase)
            .appendingPathComponent(modelRepoPath, isDirectory: true)
            .appendingPathComponent(variantFolderName(variant), isDirectory: true)
        let complete = requiredBundles.allSatisfy { contains(bundle: $0, in: folder) }
        return complete ? folder : nil
    }

    /// Mirrors `ModelUtilities.detectModelURL`: a bundle counts as present as
    /// either a compiled `.mlmodelc` or an `.mlpackage` source bundle.
    private static func contains(bundle name: String, in folder: URL) -> Bool {
        let fm = FileManager.default
        let compiled = folder.appendingPathComponent("\(name).mlmodelc")
        let package = folder.appendingPathComponent("\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel")
        return fm.fileExists(atPath: compiled.path) || fm.fileExists(atPath: package.path)
    }

    /// The config every WhisperKit load in this app goes through.
    ///
    /// `downloadBase` is always set, so a *missing* model downloads to the right
    /// place. `modelFolder` is set only when the model is already complete on
    /// disk, which is what makes the load offline-safe.
    ///
    /// `load: false` is deliberate. `WhisperKit.init` defaults `load` to
    /// `modelFolder != nil`, so simply passing a folder would add a full
    /// `loadModels()` on top of the prewarm pass this app has always used —
    /// two loads where there was one. Transcription still loads lazily on its
    /// first call (`WhisperKit.transcribe` re-checks `modelState`), exactly as
    /// before; the only thing that changes here is that no HTTP request is
    /// needed to get there.
    static func config(model: String, prewarm: Bool, base: URL? = nil) -> WhisperKitConfig {
        let base = base ?? downloadBase
        return WhisperKitConfig(model: model,
                                downloadBase: base,
                                modelFolder: cachedFolder(for: model, base: base)?.path,
                                prewarm: prewarm,
                                load: false)
    }

    // MARK: - Migration off ~/Documents

    private static let migrationDefaultsKey = "WhisperModelStore.migratedLegacyCache"

    /// Moves any models an earlier build left in `~/Documents/huggingface` into
    /// the Application Support cache, once.
    ///
    /// Without this every existing user silently re-downloads several GB, and
    /// the folder we are embarrassed about stays on their disk anyway. Moves
    /// are per-repo and skip anything already present at the destination, so a
    /// partial previous migration resumes rather than clobbering. Any failure
    /// (cross-volume, permissions, a file in use) is logged and left alone —
    /// the model simply re-downloads, which is slow but never broken.
    static func migrateLegacyCacheIfNeeded(defaults: UserDefaults = .standard,
                                           legacyRoot: URL? = nil,
                                           base: URL? = nil) {
        guard !defaults.bool(forKey: migrationDefaultsKey) else { return }
        let fm = FileManager.default
        let legacyRoot = legacyRoot ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("huggingface", isDirectory: true)
        guard fm.fileExists(atPath: legacyRoot.path) else {
            defaults.set(true, forKey: migrationDefaultsKey)   // nothing to move, never look again
            return
        }

        let legacyModels = legacyRoot.appendingPathComponent("models", isDirectory: true)
        let newModels = (base ?? downloadBase).appendingPathComponent("models", isDirectory: true)
        var movedAnything = false

        // `models/<owner>/<repo>` — move at repo granularity so an existing
        // owner directory in the destination (mlx-community already lives
        // there) is merged into rather than fought over.
        for owner in children(of: legacyModels) {
            let destOwner = newModels.appendingPathComponent(owner.lastPathComponent, isDirectory: true)
            for repo in children(of: owner) {
                let dest = destOwner.appendingPathComponent(repo.lastPathComponent, isDirectory: true)
                guard !fm.fileExists(atPath: dest.path) else { continue }   // already migrated
                do {
                    try fm.createDirectory(at: destOwner, withIntermediateDirectories: true)
                    try fm.moveItem(at: repo, to: dest)
                    movedAnything = true
                    log.notice("moved \(repo.lastPathComponent, privacy: .public) out of ~/Documents")
                } catch {
                    log.error("couldn't move \(repo.lastPathComponent, privacy: .public) out of ~/Documents: \(error.localizedDescription, privacy: .public)")
                }
            }
            pruneIfEmpty(owner)   // the owner dir is empty once its repos have gone
        }

        // Tidy up bottom-up, and only what we emptied. A leftover file means
        // something we did not put there, and it is not ours to delete.
        pruneIfEmpty(legacyModels)
        pruneIfEmpty(legacyRoot)

        defaults.set(true, forKey: migrationDefaultsKey)
        if movedAnything { log.notice("speech models now live in Application Support") }
    }

    private static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
    }

    private static func pruneIfEmpty(_ directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty || contents == [".DS_Store"] else { return }
        try? fm.removeItem(at: directory)
    }
}
