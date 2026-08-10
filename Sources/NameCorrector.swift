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
/// Organizations and products are the same problem with a different shape:
/// Whisper does not only misspell them, it re-cuts them into different words.
/// "Aramco" arrives as "a Ramco", "CloudSufi" as "Cloud Sophie". So a match is
/// made against a *window* of consecutive words rather than a single one, on
/// their letters joined together — which also catches the reverse, a
/// two-word entry heard as one. See `matches(window:name:)` for how the safety
/// bar moves with the window.
///
/// Deliberately conservative throughout: it only ever rewrites text that is not
/// already correct, is not ordinary prose, and is phonetically identical to
/// something the user actually wrote down. Everything it changes is reported so
/// the diagnostic log can carry a record of it.
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

        let (words, gaps, trailing) = split(text)
        guard !words.isEmpty else { return (text, []) }

        var out = ""
        out.reserveCapacity(text.count)
        var found: [String: Correction] = [:]
        var index = 0

        while index < words.count {
            var span = min(maximumPhraseWords, words.count - index)
            var matched = false

            // Longest first: "a Ramco" has to be considered as a phrase before
            // "Ramco" is considered on its own.
            while span >= 1 {
                if joinable(words: words, gaps: gaps, from: index, span: span),
                   let hit = replacement(for: Array(words[index ..< index + span]), in: table) {
                    out += gaps[index] + hit.text
                    found[hit.heard, default: Correction(heard: hit.heard, name: hit.name, count: 0)].count += 1
                    index += span
                    matched = true
                    break
                }
                span -= 1
            }

            if !matched {
                out += gaps[index] + words[index]
                index += 1
            }
        }

        return (out + trailing, found.values.sorted { $0.count > $1.count })
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

    /// Whether a transcript word should be rewritten as this name.
    static func matches(heard: String, name: String) -> Bool {
        matches(window: [heard], name: name)
    }

    /// Whether this run of consecutive transcript words should be rewritten as
    /// this name. The whole safety argument lives here; `skeleton` only says
    /// they sound alike.
    ///
    /// The bar moves with the window because the evidence does. One word
    /// reduced to two or three consonants finds company everywhere, so it has
    /// to be capitalized and off the stoplist to be eligible at all. A phrase
    /// carries a far longer key that chance does not reproduce, so it is enough
    /// that *some* word in it is capitalized and that the phrase is not built
    /// entirely from ordinary words — which is what lets "a Ramco" reach
    /// "Aramco" without lower-case prose becoming eligible along with it.
    static func matches(window: [String], name: String) -> Bool {
        let words = window.map { $0.filter { $0.isLetter } }
        guard !words.isEmpty, words.allSatisfy({ !$0.isEmpty }) else { return false }
        let word = words.joined()
        let target = name.filter { $0.isLetter }

        // Already right — compared as it reads, so re-cut spacing ("a Ramco")
        // still counts as wrong even though the letters alone agree.
        guard window.joined(separator: " ").caseInsensitiveCompare(name) != .orderedSame else { return false }
        // Or the user wrote something we cannot reason about phonetically (a
        // Cyrillic name, an acronym with digits).
        guard isLatinAlphabetic(word), isLatinAlphabetic(target) else { return false }

        // Whisper capitalizes the proper nouns it invents. Requiring that is
        // what keeps this away from ordinary prose, where a short skeleton
        // would otherwise have plenty of company.
        guard words.contains(where: { $0.first?.isUppercase == true }) else { return false }

        // A word people actually use is never silently renamed however well it
        // matches. Across a phrase the test is that they are not *all* ordinary
        // — "a Ramco" is reachable, "and the" is not.
        if words.count == 1 {
            guard !commonWords.contains(word.lowercased()) else { return false }
        } else {
            guard !words.allSatisfy({ commonWords.contains($0.lowercased()) }) else { return false }
        }

        // Short text carries too little signal to match on.
        guard word.count >= minimumWordLength, target.count >= minimumWordLength else { return false }

        let a = skeleton(word)
        guard a.count >= 2, a == skeleton(target) else { return false }

        // Two consonants is the shortest key this allows, and it is short
        // enough to collide with ordinary proper nouns: "John" and "HeyGen"
        // both reduce to "jn", because the `h` this drops is the very letter
        // they differ on. Where the key cannot separate them, make the opening
        // do it — Whisper keeps a word's first sound even when it loses
        // everything after it. Compared as a sound, not a letter, so "Caddy"
        // can still reach "Kadi".
        if a.count == 2 {
            guard openingSound(word) == openingSound(target) else { return false }
        }

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

    /// The sound a word opens on — the same folding `skeleton` applies, but to
    /// the first letter alone. A vowel start answers "0", as it does there.
    private static func openingSound(_ word: String) -> String {
        let letters = word.lowercased().filter { $0.isLetter }
        guard let first = letters.first else { return "" }
        if vowels.contains(first) { return "0" }
        if letters.count >= 2, let sound = digraphs[String(letters.prefix(2))] { return sound }
        return singles[first] ?? String(first)
    }

    // MARK: - Internals

    /// Text broken into its words and everything between them, so the parts
    /// that do not match can be put back exactly as they were.
    ///
    /// `gaps[i]` is the text immediately before `words[i]`; `trailing` is what
    /// follows the last word. Apostrophes stay inside a word ("Jatin's"), so
    /// the possessive does not split the name off from its ending and go
    /// uncorrected.
    private static func split(_ text: String) -> (words: [String], gaps: [String], trailing: String) {
        var words: [String] = []
        var gaps: [String] = []
        var word = ""
        var gap = ""

        for ch in text {
            if ch.isLetter || ch == "'" || ch == "\u{2019}" {
                if word.isEmpty {
                    gaps.append(gap)
                    gap = ""
                }
                word.append(ch)
            } else {
                if !word.isEmpty {
                    words.append(word)
                    word = ""
                }
                gap.append(ch)
            }
        }
        if !word.isEmpty { words.append(word) }
        return (words, gaps, gap)
    }

    /// Whether these words sit close enough together to be read as one phrase.
    /// A single space only: a name is never spelled across a comma, a line
    /// break or a sentence end, and joining over one would invent a phrase
    /// nobody said.
    private static func joinable(words: [String], gaps: [String], from index: Int, span: Int) -> Bool {
        guard span > 1 else { return true }
        return (1 ..< span).allSatisfy { gaps[index + $0] == " " }
    }

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

    /// The name to use in place of this run of words, if any. When two
    /// vocabulary entries sound the same we decline rather than guess.
    private static func replacement(
        for window: [String], in table: [String: [String]]
    ) -> (text: String, heard: String, name: String)? {
        guard let last = window.last else { return nil }
        // Only the final word may carry a possessive or contraction; an
        // apostrophe anywhere earlier means this is not one phrase.
        guard window.dropLast().allSatisfy({ $0.allSatisfy(\.isLetter) }) else { return nil }

        // The name is the leading run of letters; anything after it comes along
        // unchanged. Matching has to happen on the stem alone — folding
        // "Jathan's" down to "Jathans" gives it a trailing consonant the real
        // name does not have, and it stops sounding like "Jatin" at all.
        let stem = String(last.prefix { $0.isLetter })
        let tail = last.drop { $0.isLetter }
        guard !stem.isEmpty else { return nil }

        let phrase = Array(window.dropLast()) + [stem]
        guard let candidates = table[skeleton(phrase.joined())] else { return nil }
        let usable = candidates.filter { matches(window: phrase, name: $0) }
        guard usable.count == 1, let name = usable.first else { return nil }
        return (name + tail, window.joined(separator: " "), name)
    }

    private static func isLatinAlphabetic(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy {
            ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
        }
    }

    /// Below this a word is more likely to collide than to match.
    static let minimumWordLength = 3

    /// How many consecutive words may be read as one name. Four covers the
    /// organizations people actually write down ("AI Center of Excellence")
    /// and the articles Whisper glues onto them.
    static let maximumPhraseWords = 4

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// Two letters, one sound.
    private static let digraphs: [String: String] = [
        "ph": "f", "th": "t", "sh": "s", "ch": "k", "ck": "k",
        "kh": "k", "zh": "s", "gh": "",
    ]

    /// Letters that sound like other letters. Kept short on purpose — every
    /// entry merges two sounds into one and widens what can collide.
    ///
    /// `g` folds into `j`, not `k`: a soft g is what Whisper actually
    /// substitutes ("HeyGen" -> "Heijen", "Hagen"), while hearing it as a hard
    /// k is not a mistake it makes. Merging the two would put "Greg" and
    /// "Craig" in one bucket for no gain.
    private static let singles: [Character: String] = [
        "c": "k", "q": "k", "x": "ks", "z": "s", "w": "v", "g": "j",
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
        // Short nouns that turn up capitalized in meeting prose and reduce to
        // the same two consonants as a real name — "QR Code" must not become
        // "QR Kadi". A name that collides with one of these stays uncorrected,
        // which is the trade this file makes everywhere.
        "code", "data", "date", "site", "page", "user", "note", "list", "mode",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
    ]
}
