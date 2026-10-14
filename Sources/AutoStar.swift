import Foundation

/// The moments Seal stars on its own as the transcript lands: someone saying
/// your name, a decision, a task with a deadline. Plain phrase cues in English
/// and Ukrainian — no model call — so it keeps up with live speech, costs
/// nothing, and does the same thing every time. Its stars are lighter than the
/// user's own (☆, not ★), say why they are there, and quote what was said.
enum AutoStar {
    enum Reason: String, Equatable {
        case name, decision, task

        /// How the star names itself in the notes.
        var label: String {
            switch self {
            case .name: return "Said your name"
            case .decision: return "Decision"
            case .task: return "Task"
            }
        }
    }

    struct Hit: Equatable {
        let reason: Reason
        /// The sentence that set it off, trimmed for the notes.
        let quote: String
    }

    /// The note a hit is filed as: ☆, the reason, and the quote.
    static func noteText(for hit: Hit) -> String {
        "☆ \(hit.reason.label): “\(hit.quote)”"
    }

    /// What, if anything, in one utterance deserves a star. Your name counts
    /// only from the call's side — you saying it is an introduction, not a
    /// question for you.
    static func detect(_ text: String, fromOthers: Bool, userName: String) -> Hit? {
        let sentences = Self.sentences(in: text)
        if fromOthers {
            let names = namePatterns(for: userName)
            if !names.isEmpty, let s = sentences.first(where: { s in names.contains { matches($0, s) } }) {
                return Hit(reason: .name, quote: trimmed(s))
            }
        }
        if let s = sentences.first(where: isDecision) { return Hit(reason: .decision, quote: trimmed(s)) }
        if let s = sentences.first(where: isTask) { return Hit(reason: .task, quote: trimmed(s)) }
        return nil
    }

    // MARK: - Cues

    // Lowercased text, apostrophes straightened. A cue must start and end at
    // a word's edge ("agreed" is not inside "disagreed").
    private static let decisions = cues([
        "we(?:'ve| have)? (?:just )?decided", "it's decided", "it is decided",
        "(?:the|our|final) decision (?:is|was)", "let's go (?:ahead )?with",
        "we(?:'ll| will) go with", "we(?:'re| are) going (?:to go )?with",
        "we(?:'ve| have)? agreed", "agreed on", "we(?:'re| are) aligned on", "let's lock (?:it|that|this) in",
        // Ukrainian
        "(?:ми )?вирішили", "вирішено", "домовил(?:ися|ись|ася|ась|ося|ось)", "погодил(?:ися|ись)",
        "зупин(?:имось|имося|илися|ились) на", "так і (?:робимо|зробимо)", "робимо так",
        "рішення (?:таке|прийнято|ухвалено)",
    ])

    private static let explicitTasks = cues([
        "action items?", "deadline", "due (?:by|on)",
        "дедлайн", "екшн айтем(?:и)?",
    ])

    /// Asking someone to do a thing.
    private static let requests = cues([
        "(?:can|could|would|will) you", "please",
        "мож(?:еш|ете)", "змож(?:еш|ете)", "могли б", "будь ласка",
        "зроб(?:и|іть|иш|ите)", "надішл(?:и|іть|еш|ете)", "відправ(?:те)?", "підготу(?:й|йте|єш|єте)",
        "перевір(?:те)?", "напиш(?:и|іть)", "скин(?:ь|ьте)",
    ])

    /// Taking a thing on, or saying it must be done.
    private static let commitments = cues([
        "i(?:'ll| will)", "you(?:'ll| will)", "we(?:'ll| will)", "(?:i|you|we) need to", "make sure", "let's",
        "я (?:зроблю|надішлю|відправлю|підготую|перевірю|напишу|скину)", "зробимо", "треба", "потрібно",
        "маємо", "мусимо",
    ])

    /// A when that makes it a task: by Friday, до п'ятниці, end of the week.
    private static let deadlines = cues([
        "(?:by|before|until|till) (?:the )?(?:end of (?:the )?(?:day|week|month)|eod|eow|tomorrow|tonight|noon"
            + "|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next (?:week|month)|this (?:week|friday)"
            + "|\\d{1,2}(?:st|nd|rd|th)?)",
        "end of (?:the )?(?:day|week)", "eod", "eow",
        "до (?:понеділка|вівторка|середи|четверга|п'ятниці|суботи|неділі|завтра|вечора|обіду|ранку"
            + "|кінця (?:дня|тижня|місяця)|наступного тижня|\\d{1,2})",
        "(?:на )?наступному тижні", "наступного тижня",
    ])

    /// A softer when, enough only with a direct request ("can you send it
    /// tomorrow?" — but not "I'll see you tomorrow").
    private static let soonish = cues(["tomorrow", "today", "tonight", "next week", "завтра", "сьогодні"])

    private static func isDecision(_ sentence: String) -> Bool {
        decisions.contains { matches($0, sentence) }
    }

    private static func isTask(_ sentence: String) -> Bool {
        if explicitTasks.contains(where: { matches($0, sentence) }) { return true }
        let asked = requests.contains { matches($0, sentence) }
        let taken = commitments.contains { matches($0, sentence) }
        guard asked || taken else { return false }
        if deadlines.contains(where: { matches($0, sentence) }) { return true }
        return asked && soonish.contains { matches($0, sentence) }
    }

    // MARK: - Your name

    /// The ways your first name can be heard: as typed (English names don't
    /// change, so the whole word), and in the other alphabet — where Ukrainian
    /// changes a name's ending when it is addressed ("Дмитре") or owned
    /// ("Дмитра"), so the stem with the usual endings.
    static func namePatterns(for userName: String) -> [NSRegularExpression] {
        let first = userName.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
        let name = first.lowercased()
        guard name.count >= 3 else { return [] }
        let typedInLatin = name.unicodeScalars.allSatisfy { $0.isASCII }
        let forms = typedInLatin ? [(name, true), (cyrillic(fromLatin: name), false)]
                                 : [(name, false), (latin(fromCyrillic: name), true)]
        let patterns = forms.filter { $0.0.count >= 3 }.map { form, isLatin -> String in
            let escaped = NSRegularExpression.escapedPattern(for: form)
            if isLatin { return escaped }
            var stem = form
            if let last = stem.last, "оаяйіїеєиу".contains(last), stem.count >= 4 { stem.removeLast() }
            return NSRegularExpression.escapedPattern(for: stem) + "(?:а|я|у|ю|е|є|о|ом|ем|ою|ею|ові|еві|і|ї|й|и)?"
        }
        return cues(Array(Set(patterns)).sorted())
    }

    /// Ukrainian's Latin spelling read back into Cyrillic, longest letters first.
    static func cyrillic(fromLatin text: String) -> String {
        let pairs: [(String, String)] = [
            ("shch", "щ"), ("zgh", "зг"), ("zh", "ж"), ("kh", "х"), ("ts", "ц"), ("ch", "ч"), ("sh", "ш"),
            ("yu", "ю"), ("ya", "я"), ("ye", "є"), ("yi", "ї"), ("iu", "ю"), ("ia", "я"), ("ie", "є"),
            ("a", "а"), ("b", "б"), ("v", "в"), ("h", "г"), ("g", "г"), ("d", "д"), ("e", "е"), ("z", "з"),
            ("y", "и"), ("i", "і"), ("k", "к"), ("l", "л"), ("m", "м"), ("n", "н"), ("o", "о"), ("p", "п"),
            ("r", "р"), ("s", "с"), ("t", "т"), ("u", "у"), ("f", "ф"), ("j", "й"), ("c", "к"), ("w", "в"),
            ("x", "кс"), ("q", "к"),
        ]
        var out = ""
        var rest = Substring(text)
        outer: while !rest.isEmpty {
            for (latin, cyr) in pairs where rest.hasPrefix(latin) {
                out += cyr
                rest = rest.dropFirst(latin.count)
                continue outer
            }
            out.append(rest.removeFirst())
        }
        return out
    }

    /// Cyrillic spelled the Ukrainian way in Latin letters.
    static func latin(fromCyrillic text: String) -> String {
        let map: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "e", "є": "ye", "ж": "zh",
            "з": "z", "и": "y", "і": "i", "ї": "yi", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n",
            "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
            "ч": "ch", "ш": "sh", "щ": "shch", "ь": "", "ю": "yu", "я": "ya", "'": "",
            "ы": "y", "э": "e", "ё": "yo", "ъ": "",
        ]
        return text.map { map[$0] ?? String($0) }.joined()
    }

    // MARK: - Text

    private static func cues(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap {
            try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}'])(?:\($0))(?![\\p{L}\\p{N}])", options: [])
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ sentence: String) -> Bool {
        let lowered = normalized(sentence)
        return regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "`", with: "'")
    }

    /// The utterance cut into sentences at . ? ! … and line breaks.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c == "\n" {
                result.append(current)
                current = ""
                continue
            }
            current.append(c)
            if ".?!…".contains(c), i + 1 == chars.count || chars[i + 1].isWhitespace {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// At most 120 characters, cut at a word.
    private static func trimmed(_ sentence: String) -> String {
        guard sentence.count > 120 else { return sentence }
        let cut = sentence.prefix(120)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}
