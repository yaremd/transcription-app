import Foundation
import Hub
import Tokenizers
import MLXLLM
import MLXLMCommon
import MLXHuggingFace

/// On-device LLM used for notes, titles, and chat — the shipping replacement for
/// the dev-time Ollama backend. Runs a small instruct model locally via MLX
/// (Apple Silicon), auto-downloading its weights from Hugging Face on first use,
/// exactly like WhisperKit fetches its speech models. Nothing leaves the Mac.
///
/// The model is loaded once and reused. Loading and generation are serialized by
/// the actor so the single in-memory model is never used concurrently.
actor MLXEngine {
    static let shared = MLXEngine()

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// On-device model ids — both 4-bit and strongly multilingual (English /
    /// Ukrainian / Russian), same family so prompts transfer between them.
    static let model7B = "mlx-community/Qwen2.5-7B-Instruct-4bit"   // ~4.3 GB
    static let model3B = "mlx-community/Qwen2.5-3B-Instruct-4bit"   // ~1.9 GB

    /// The model to use, chosen automatically by the machine's RAM (the user
    /// never picks). The 7B writes better notes but needs headroom alongside the
    /// OS and the speech model, so 8 GB Macs fall back to the 3B.
    static var defaultModelID: String {
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return ramGB >= 12 ? model7B : model3B
    }

    /// MLX only runs on Apple Silicon; Intel Macs fall back to the cloud option.
    static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private var container: ModelContainer?
    private var loadedModelID: String?
    private var loadTask: Task<ModelContainer, Error>?

    /// 0…1 while the weights download on first use; 1 once the model is ready.
    private(set) var downloadProgress: Double = 0
    private var progressObserver: (@Sendable (Double) -> Void)?

    /// Lets the UI observe first-run download progress.
    func setProgressObserver(_ observer: (@Sendable (Double) -> Void)?) {
        progressObserver = observer
    }

    /// Whether the model weights are already loaded in memory (no download/UI needed).
    var isReady: Bool { container != nil }

    /// Generate a completion for a system + user prompt. One-shot: a fresh
    /// `ChatSession` per call so unrelated jobs (titles, notes, chat) never share
    /// context. Downloads and loads the model on first call.
    func generate(system: String,
                  user: String,
                  maxTokens: Int = 1200,
                  temperature: Float = 0.3,
                  modelID: String = MLXEngine.defaultModelID) async throws -> String {
        guard Self.isSupported else {
            throw EngineError(message: "On-device notes need an Apple-silicon Mac. Turn on a cloud model in Settings to use notes here.")
        }
        let container = try await ensureLoaded(modelID: modelID)
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: temperature))
        let output = try await session.respond(to: user)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EngineError(message: "The on-device model returned an empty response. Try again.")
        }
        return trimmed
    }

    /// Pre-download / warm the model without generating (for onboarding).
    @discardableResult
    func prewarm(modelID: String = MLXEngine.defaultModelID) async throws -> Bool {
        _ = try await ensureLoaded(modelID: modelID)
        return true
    }

    // MARK: - Loading

    /// Load the model once, downloading on first use. Concurrent callers share a
    /// single in-flight load task.
    private func ensureLoaded(modelID: String) async throws -> ModelContainer {
        if let container, loadedModelID == modelID { return container }
        if let loadTask, loadedModelID == modelID { return try await loadTask.value }

        loadedModelID = modelID
        let downloader = HubSnapshotDownloader(hubApi: Self.makeHubApi())
        let tokenizerLoader = TransformersTokenizerLoader()
        let task = Task { () throws -> ModelContainer in
            try await loadModelContainer(from: downloader, using: tokenizerLoader, id: modelID) { progress in
                let fraction = progress.fractionCompleted
                Task { await self.updateProgress(fraction) }
            }
        }
        loadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            downloadProgress = 1
            progressObserver?(1)
            return loaded
        } catch {
            // Allow a retry after a failed download/load.
            loadTask = nil
            loadedModelID = nil
            throw error
        }
    }

    private func updateProgress(_ fraction: Double) {
        downloadProgress = fraction
        progressObserver?(fraction)
    }

    /// Models live under Application Support so they persist and stay out of the
    /// user's visible Documents folder.
    private static func makeHubApi() -> HubApi {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Seal/models", isDirectory: true)
        return HubApi(downloadBase: base)
    }
}

/// Adapts swift-transformers' `HubApi` (the same downloader WhisperKit already
/// uses) to MLX's `Downloader` protocol, so the LLM and the speech model share
/// one Hugging Face download stack.
private struct HubSnapshotDownloader: Downloader {
    let hubApi: HubApi

    func download(id: String,
                  revision: String?,
                  matching patterns: [String],
                  useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        try await hubApi.snapshot(from: id,
                                  revision: revision ?? "main",
                                  matching: patterns,
                                  progressHandler: progressHandler)
    }
}

/// Loads a Hugging Face tokenizer from a local model folder and adapts it to
/// MLX's `Tokenizer` protocol via the MLXHuggingFace macro.
private struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return #adaptHuggingFaceTokenizer(upstream)
    }
}
