import Foundation
import Combine

/// Stores the user's custom vocabulary — the names Seal should spell right.
/// Persisted in UserDefaults (a small string list) and never leaves the machine.
///
/// These are applied to the transcript *after* it is decoded, by
/// `NameCorrector`. They are still offered to Whisper as a decoder prompt, but
/// that path is unreliable enough that it gives up on itself mid-session (see
/// `Transcriber.promptIsWorthTrying`) — the correction is what actually fixes
/// the spelling.
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
