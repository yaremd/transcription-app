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

    /// Mirrors `ModelUtilities.detectModelURL` in *where* it looks — a compiled
    /// `.mlmodelc` or an `.mlpackage` source bundle — but asks a harder question
    /// than "does the path exist".
    ///
    /// A `.mlmodelc` is a directory, and an interrupted download creates it,
    /// writes the small descriptors, and only then pulls the parameters. Caught
    /// mid-flight on 2026-08-14: an `AudioEncoder.mlmodelc` of **440 KB** with
    /// `analytics/`, `coremldata.bin` and `model.mlmodel` present and no
    /// `weights/` — against 1.2 GB for the finished article. Existence alone
    /// therefore calls a 13 MB fragment of a 1.5 GB model "cached", hands it to
    /// WhisperKit as a `modelFolder`, and produces exactly the permanent
    /// local-load failure this check exists to prevent.
    ///
    /// `weights/` is the discriminator: present in every complete variant on
    /// disk, from base.en (40 MB) to large-v3 (1.2 GB), and absent from the
    /// half-written one. Requiring it costs a directory read and turns that
    /// dead end back into a resumable download.
    private static func contains(bundle name: String, in folder: URL) -> Bool {
        let compiled = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if hasWeights(compiled) { return true }
        // `.mlpackage` keeps the same split one level deeper.
        let package = folder.appendingPathComponent("\(name).mlpackage/Data/com.apple.CoreML", isDirectory: true)
        return hasWeights(package)
            && FileManager.default.fileExists(atPath: package.appendingPathComponent("model.mlmodel").path)
    }

    /// Whether a compiled model bundle actually carries its parameters.
    private static func hasWeights(_ bundle: URL) -> Bool {
        let weights = bundle.appendingPathComponent("weights", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: weights.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return !children(of: weights).isEmpty
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
    /// the folder we are embarrassed about stays on their disk anyway. Any
    /// failure (cross-volume, permissions, a file in use) is logged and left
    /// alone — the model simply re-downloads, which is slow but never broken.
    ///
    /// The move merges rather than moving whole repos. Skipping a repo whose
    /// destination directory exists sounds safe and is not: a single
    /// half-downloaded variant at the destination is enough to make the
    /// directory exist, and the entire real cache then stays in ~/Documents
    /// forever. Found exactly that way on 2026-08-14, where 54 MB of aborted
    /// download would have stranded 9.2 GB. See `merge`.
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

        for owner in children(of: legacyModels) {
            let destOwner = newModels.appendingPathComponent(owner.lastPathComponent, isDirectory: true)
            for repo in children(of: owner) {
                let dest = destOwner.appendingPathComponent(repo.lastPathComponent, isDirectory: true)
                if merge(repo, into: dest) { movedAnything = true }
                pruneIfEmpty(repo)    // whatever merged away leaves an empty shell
            }
            pruneIfEmpty(owner)       // and the owner dir once its repos have gone
        }

        // Tidy up bottom-up, and only what we emptied. A leftover file means
        // something we did not put there, and it is not ours to delete.
        pruneIfEmpty(legacyModels)
        pruneIfEmpty(legacyRoot)

        defaults.set(true, forKey: migrationDefaultsKey)
        if movedAnything { log.notice("speech models now live in Application Support") }
    }

    /// Moves `source` to `destination`, merging where something is already
    /// there. Returns whether anything actually moved.
    ///
    /// Nothing at the destination is the common case and takes the fast path:
    /// one rename, instant on the same volume whatever the size. Otherwise the
    /// two are merged child by child, and on a genuine conflict the
    /// destination is kept — with one exception, which is the point of the
    /// exercise. A model folder that is *incomplete* loses to a complete one
    /// coming the other way: an aborted download has no business outranking
    /// the model the user actually has, and it is precisely what would be
    /// sitting at the destination after a first run that was interrupted.
    @discardableResult
    private static func merge(_ source: URL, into destination: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: destination)
                log.notice("moved \(source.lastPathComponent, privacy: .public) out of ~/Documents")
                return true
            } catch {
                log.error("couldn't move \(source.lastPathComponent, privacy: .public) out of ~/Documents: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        if looksLikeModelFolder(source), !isCompleteModelFolder(destination), isCompleteModelFolder(source) {
            do {
                try fm.removeItem(at: destination)          // the half-written one
                try fm.moveItem(at: source, to: destination)
                log.notice("replaced a half-downloaded \(source.lastPathComponent, privacy: .public) with the complete one")
                return true
            } catch {
                log.error("couldn't replace half-downloaded \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        guard isDirectory(source), isDirectory(destination) else { return false }
        var moved = false
        for child in children(of: source) {
            if merge(child, into: destination.appendingPathComponent(child.lastPathComponent)) { moved = true }
        }
        // A directory whose children all moved out is spent. Pruning here
        // rather than only at repo level matters because the prune chain is
        // bottom-up: one surviving empty directory anywhere down the tree —
        // `.cache/huggingface/download` is the one that turned up — keeps every
        // directory above it non-empty, and `~/Documents/huggingface` stays on
        // screen having been emptied of everything that justified it.
        pruneIfEmpty(source)
        return moved
    }

    private static func looksLikeModelFolder(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("openai_whisper-")
    }

    private static func isCompleteModelFolder(_ url: URL) -> Bool {
        requiredBundles.allSatisfy { contains(bundle: $0, in: url) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Hidden entries are deliberately included. `HubApi` keeps its download
    /// bookkeeping in a `.cache` directory beside the models — 170 MB of it on
    /// the machine this was tested on — and skipping it had two consequences,
    /// both wrong: the bookkeeping was orphaned from the models it describes,
    /// and because it stayed put, `pruneIfEmpty` found `~/Documents/huggingface`
    /// non-empty and left the whole folder sitting there. The migration moved
    /// 9 GB and still failed at the part the user would actually notice.
    private static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func pruneIfEmpty(_ directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty || contents == [".DS_Store"] else { return }
        try? fm.removeItem(at: directory)
    }
}
