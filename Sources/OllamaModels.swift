import Foundation

/// One locally-installed Ollama model, with its on-disk size.
struct OllamaModel: Identifiable, Hashable {
    let name: String
    let sizeBytes: Int64
    var id: String { name }

    var sizeLabel: String {
        let gb = Double(sizeBytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(sizeBytes) / 1_000_000)
    }
}

/// Reads the list of installed models straight from the local Ollama server.
/// Read-only and best-effort: if Ollama isn't running it simply returns [].
enum OllamaModels {
    static func installed() async -> [OllamaModel] {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models
            .compactMap { entry -> OllamaModel? in
                guard let name = entry["name"] as? String else { return nil }
                let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
                return OllamaModel(name: name, sizeBytes: size)
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }   // lightest first
    }
}
