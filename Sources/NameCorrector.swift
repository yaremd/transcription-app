import Foundation

/// Repairs the spelling of known names in a finished transcript.
///
/// Whisper hears names it does not know as the nearest thing it does know, and
/// it is consistently close: "Dmytro" arrives as Demitra, Dimitri, Demetra;
/// "Kriti" as Krithi; "Jatin" as Jathan; "Nehil" as Neil. The consonants
/// survive and the vowels do not, which is exactly what a phonetic match is
/// good at.
///
/// This replaced the custom vocabulary's original job. That was implemented as
/// a Whisper decoder prompt, which on the 2026-08-05 planning call reached the
/// model on one pass in ten, doubled the decode work on the rest, and still
/// spelled both names wrong — see `Transcriber.promptIsWorthTrying`. Correcting
/// the text afterwards costs a string scan, cannot cost a line, and can be read
/// and reversed by a person.
///
/// Deliberately conservative: it only ever rewrites a capitalized word that is
/// not already a name, not a common word, and phonetically identical to one the
/// user actually wrote down. Everything it changes is reported so the diagnostic
/// log can carry a record of it.
enum NameCorrector {

    /// One name repaired, and how often.
    struct Correction: Equatable, Hashable {
        let heard: String     // the spelling that was in the transcript
        let name: String      // the spelling the user wrote down
        var count: Int
    }

    // MARK: - Correcting text

    /// Rewrites near-miss spellings of `names` in `text`. Punctuation, spacing
    /// and every other word are left exactly as they were.
    static func corrected(_ text: String, names: [String]) -> String {
        correcting(text, names: names).text
    }

    /// The same, reporting what changed.
    static func correcting(_ text: String, names: [String]) -> (text: String, corrections: [Correction]) {
        let table = lookup(for: names)
        guard !table.isEmpty else { return (text, []) }

        var out = ""
        out.reserveCapacity(text.count)
        var token = ""
        var found: [String: Correction] = [:]

        func flushToken() {
            guard !token.isEmpty else { return }
            if let name = replacement(for: token, in: table) {
                found[token, default: Correction(heard: token, name: name, count: 0)].count += 1
                out += name
            } else {
                out += token
            }
            token = ""
        }

        for ch in text {
            // Apostrophes stay inside a word ("Jatin's"), so the possessive
            // does not split the name off from its ending and go uncorrected.
            if ch.isLetter || ch == "'" || ch == "\u{2019}" {
                token.append(ch)
            } else {
                flushToken()
                out.append(ch)
            }
        }
        flushToken()
        return (out, found.values.sorted { $0.count > $1.count })
    }

    /// Corrects a stored transcript, reporting the total repairs across it.
    static func correcting(_ lines: [StoredLine], names: [String]) -> (lines: [StoredLine], corrections: [Correction]) {
        var totals: [String: Correction] = [:]
        let fixed = lines.map { line -> StoredLine in
            let (text, found) = correcting(line.text, names: names)
            for correction in found {
                totals[correction.heard, default: Correction(heard: correction.heard, name: correction.name, count: 0)]
                    .count += correction.count
            }
            var line = line
            line.text = text
            return line
        }
        return (fixed, totals.values.sorted { $0.count > $1.count })
    }

    // MARK: - Matching

    /// Whether a transcript word should be rewritten as this name. The whole
    /// safety argument lives here; `skeleton` only says they sound alike.
    static func matches(heard: String, name: String) -> Bool {
        let word = heard.filter { $0.isLetter }
        let target = name.filter { $0.isLetter }
        // Already right, or the user wrote something we cannot reason about
        // phonetically (a Cyrillic name, an acronym with digits).
        guard word.lowercased() != target.lowercased(),
              isLatinAlphabetic(word), isLatinAlphabetic(target) else { return false }
        // Whisper capitalizes the names it invents. Requiring that is what
        // keeps this away from ordinary prose, where a two-consonant skeleton
        // would otherwise have plenty of company.
        guard word.first?.isUppercase == true else { return false }
        // Short words carry too little signal, and a word people actually use
        // is never silently renamed however well it matches.
        guard word.count >= minimumWordLength, target.count >= minimumWordLength,
              !commonWords.contains(word.lowercased()) else { return false }
        let a = skeleton(word)
        guard a.count >= 2, a == skeleton(target) else { return false }
        // A name is misheard, not replaced wholesale: "Adi" must never absorb
        // "Adityu", which is a different (longer) name entirely.
        return abs(word.count - target.count) <= max(2, target.count / 2)
    }

    /// What a spelling sounds like, reduced to its consonants.
    ///
    /// Vowels are what Whisper loses, so they are what this ignores — as is
    /// `h`, which it hears or does not ("Nehil"/"Neil"). Digraphs fold to the
    /// single sound they make, so "Jathan" and "Jatin" agree. A word that
    /// begins on a vowel keeps a marker for it, so "Adi" and "Dee" stay apart.
    static func skeleton(_ word: String) -> String {
        let letters = word.lowercased().filter { $0.isLetter }
        guard let first = letters.first else { return "" }

        var folded = ""
        var index = letters.startIndex
        while index < letters.endIndex {
            let ch = letters[index]
            let next = letters.index(after: index)
            if next < letters.endIndex, let sound = digraphs[String([ch, letters[next]])] {
                folded += sound
                index = letters.index(after: next)
                continue
            }
            folded.append(ch)
            index = next
        }

        var key = vowels.contains(first) ? "0" : ""      // marks a vowel start
        for ch in folded {
            guard !vowels.contains(ch), ch != "h" else { continue }
            let sound = singles[ch] ?? String(ch)
            if key.last.map({ String($0) }) == sound { continue }   // collapse doubles
            key += sound
        }
        return key
    }

    // MARK: - Internals

    private static func lookup(for names: [String]) -> [String: [String]] {
        var table: [String: [String]] = [:]
        for name in names {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = cleaned.filter { $0.isLetter }
            guard letters.count >= minimumWordLength, isLatinAlphabetic(letters) else { continue }
            let key = skeleton(letters)
            guard key.count >= 2 else { continue }
            table[key, default: []].append(cleaned)
        }
        return table
    }

    /// The name to use in place of this word, if any. When two vocabulary
    /// entries sound the same we decline rather than guess.
    private static func replacement(for token: String, in table: [String: [String]]) -> String? {
        // The name is the leading run of letters; anything after it is a
        // possessive or contraction and comes along unchanged. Matching has to
        // happen on the stem alone — folding "Jathan's" down to "Jathans"
        // gives it a trailing consonant the real name does not have, and it
        // stops sounding like "Jatin" at all.
        let stem = String(token.prefix { $0.isLetter })
        let tail = token.drop { $0.isLetter }
        guard let candidates = table[skeleton(stem)] else { return nil }
        let usable = candidates.filter { matches(heard: stem, name: $0) }
        guard usable.count == 1, let name = usable.first else { return nil }
        return name + tail
    }

    private static func isLatinAlphabetic(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
        }
    }

    /// Below this a word is more likely to collide than to match.
    static let minimumWordLength = 3

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// Two letters, one sound.
    private static let digraphs: [String: String] = [
        "ph": "f", "th": "t", "sh": "s", "ch": "k", "ck": "k",
        "kh": "k", "zh": "s", "gh": "",
    ]

    /// Letters that sound like other letters. Kept short on purpose — every
    /// entry merges two sounds into one and widens what can collide. `g` is
    /// deliberately not folded into `k` for that reason.
    private static let singles: [Character: String] = [
        "c": "k", "q": "k", "x": "ks", "z": "s", "w": "v",
    ]

    /// Words this never renames, however well they match — the capitalized
    /// company a transcript keeps. Sentence openers, mostly: without this a
    /// vocabulary entry like "Tanya" would rewrite every "Then" in the file.
    private static let commonWords: Set<String> = [
        "the", "then", "than", "that", "this", "these", "those", "there", "their", "they",
        "and", "but", "for", "not", "you", "your", "yes", "yeah", "yep", "okay",
        "was", "were", "are", "our", "out", "one", "two", "three", "four", "five",
        "can", "could", "would", "should", "will", "shall", "may", "might", "must",
        "have", "has", "had", "how", "who", "why", "what", "when", "where", "which",
        "with", "without", "from", "into", "over", "under", "after", "before",
        "some", "any", "all", "both", "each", "more", "most", "much", "many",
        "just", "only", "also", "even", "still", "such", "same", "other", "another",
        "let", "lets", "get", "got", "give", "take", "make", "made", "made", "come",
        "see", "say", "said", "know", "think", "want", "need", "like", "look",
        "now", "new", "next", "last", "first", "second", "third", "here", "very",
        "sure", "sorry", "thanks", "thank", "hello", "hey", "right", "left", "well",
        "actually", "basically", "maybe", "because", "since", "while", "until",
        "sir", "please", "again", "about", "above", "below", "between", "through",
        "team", "call", "meeting", "week", "day", "time", "part", "thing", "things",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
    ]
}
