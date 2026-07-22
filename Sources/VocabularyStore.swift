import Foundation
import Combine

/// Stores the user's custom vocabulary — names, acronyms, and jargon that the
/// transcriber should recognize. Persisted in UserDefaults (a small string
/// list). Applied as a Whisper decoder prompt, so it works in any language and
/// never leaves the machine.
final class VocabularyStore: ObservableObject {
    @Published var terms: [String] {
        didSet { UserDefaults.standard.set(terms, forKey: Self.key) }
    }

    private static let key = "customVocabulary"

    init() {
        terms = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func add(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty,
              !terms.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        terms.append(t)
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
    }
}
