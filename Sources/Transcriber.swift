import Foundation
import WhisperKit

/// Thin actor around WhisperKit. Loads a multilingual Whisper model on-device
/// and turns 16 kHz mono Float audio into text. Language can be forced (e.g.
/// "uk") or left to auto-detect. The actor serializes access so the mic and
/// system-audio streams can share one model.
actor Transcriber {
    private var pipe: WhisperKit?
    private var language: String?          // ISO code like "uk"/"en"; nil = auto-detect
    private(set) var loadedModel: String?
    private var vocabularyPrompt = ""      // custom terms joined into a Whisper prompt
    private var cachedPromptTokens: [Int]?

    /// Sets the custom vocabulary that biases transcription toward the user's
    /// names/jargon. Tokenized lazily on the next transcribe (it needs the loaded
    /// model's tokenizer). A decoder prompt, so it works in any language.
    func setVocabulary(_ terms: [String]) {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        vocabularyPrompt = cleaned.joined(separator: ", ")
        cachedPromptTokens = nil
    }

    var isLoaded: Bool { pipe != nil }

    func setLanguage(_ code: String?) {
        language = code
    }

    /// Unloads the current model so the next load() can pick a different one
    /// (used when the user flips the Fast/Accurate switch).
    func reset() {
        pipe = nil
        loadedModel = nil
        cachedPromptTokens = nil   // the tokenizer changes with the new model
    }

    func load(candidates: [String]) async throws {
        guard pipe == nil else { return }
        var lastError: Error?
        for name in candidates {
            do {
                pipe = try await WhisperKit(WhisperKitConfig(model: name, prewarm: true))
                loadedModel = name
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "Transcriber", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "No transcription model could be loaded."])
    }

    func transcribe(_ samples: [Float]) async -> String {
        guard let pipe, !samples.isEmpty else { return "" }
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language            // nil = let Whisper detect
        options.detectLanguage = (language == nil)
        if !vocabularyPrompt.isEmpty {
            if cachedPromptTokens == nil, let tok = pipe.tokenizer {
                cachedPromptTokens = tok.encode(text: " " + vocabularyPrompt)
                    .filter { $0 < tok.specialTokens.specialTokenBegin }
            }
            options.promptTokens = cachedPromptTokens
        }
        do {
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            return results
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
}
