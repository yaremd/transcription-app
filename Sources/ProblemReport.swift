import Foundation

/// Turns a meeting's diagnostics into something a stranger can send you.
///
/// Seal has no telemetry and is not getting any — so the only way a problem
/// ever reaches the developer is if the person who hit it can describe it. They
/// cannot: a transcript that quietly lost forty seconds reads as merely
/// mediocre. The `.diag.log` beside every meeting knows exactly what happened,
/// and every bug found in the week of 2026-08-05 was diagnosed by counting its
/// lines — 1157 `empty-segment` drops, 8 utterances that decoded to nothing,
/// 1083 decodes retried without the vocabulary prompt. Those counts are the
/// diagnosis.
///
/// And counts are all this sends. The log itself quotes what was said, so the
/// summary is built to carry none of it: totals, durations and reason names
/// only, assembled here so the person reporting can read the whole thing before
/// it goes anywhere. Attaching the full log is a separate, explicit choice.
struct ProblemReport {

    // MARK: - What the log says

    /// Counted facts about one recording. Nothing here is derived from what
    /// anybody said — only from how the decoder behaved.
    struct Diagnostics: Equatable {
        var sessionLine = ""                       // "speed=fast language=auto keepAudio=true"
        var utterancesDecoded = 0
        var utterancesEmpty = 0                    // decoded, produced no text
        var secondsDecoded = 0.0
        var secondsEmpty = 0.0
        var utterancesSkipped = 0                  // too little speech to try
        var segmentDrops: [String: Int] = [:]      // reason -> count
        var guardDrops: [String: Int] = [:]        // "bootstrap stock filler" -> count
        var votes: [String: Int] = [:]             // language -> committed votes
        var detectionsOutsideAllowedSet = 0
        var promptRetries = 0                      // decodes re-run without the vocabulary
        var promptAbandoned = false
        var namesCorrected = 0
        var decodeSecondsMax = 0.0
        var queueSecondsMax = 0.0                  // longest an utterance waited its turn
        var decodeErrors = 0
        var stalls = 0
        var truncated = false

        /// The share of decoded speech that came back as nothing. The number
        /// that said "something is badly wrong" on both of the 2026-08-05
        /// recordings, before anyone knew what.
        var emptyShare: Double { secondsDecoded > 0 ? secondsEmpty / secondsDecoded : 0 }
    }

    /// Reads a diagnostics log. Written to survive a log from an older build:
    /// anything unrecognized is simply not counted.
    static func diagnostics(fromLog log: String) -> Diagnostics {
        var d = Diagnostics()
        /// Seconds of audio each committed utterance was given, keyed by the
        /// stream and number in its "-> N.Ns to decode" line, so the later
        /// "-> EMPTY" line can be priced.
        var pending: [String: Double] = [:]

        for raw in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.contains("--- diagnostics truncated") { d.truncated = true; continue }
            if let session = line.range(of: "session start — ") {
                d.sessionLine = String(line[session.upperBound...])
                continue
            }
            if let reason = value(in: line, after: "seg-drop ", upTo: " ") {
                d.segmentDrops[reason, default: 0] += 1
                continue
            }
            if line.contains("PROMPT ABANDONED") { d.promptAbandoned = true; continue }
            if line.contains("empty with a prompt, retried without") { d.promptRetries += 1; continue }
            if line.contains("DECODE THREW") { d.decodeErrors += 1; continue }
            if line.contains("did not finish in time") || line.contains("stalled beyond") { d.stalls += 1; continue }
            // Every logged line carries a timestamp prefix, so this matches on
            // the marker in place rather than at the start of the string.
            if line.contains(" name: \"") { d.namesCorrected += 1; continue }
            if let lang = value(in: line, after: "VOTE ", upTo: " ") {
                d.votes[lang, default: 0] += 1
                continue
            }
            if line.contains("inAllowed=false") { d.detectionsOutsideAllowedSet += 1; continue }
            if let kind = dropKind(in: line) { d.guardDrops[kind, default: 0] += 1; continue }

            // Commit bookkeeping. Two lines per utterance: one when it is
            // handed over, one when it comes back.
            if let key = commitKey(in: line) {
                if line.contains("SKIPPED (too little speech)") {
                    d.utterancesSkipped += 1
                } else if let secs = double(in: line, before: "s to decode") {
                    pending[key] = secs
                } else if line.contains("queued=") {
                    let secs = pending.removeValue(forKey: key) ?? 0
                    d.utterancesDecoded += 1
                    d.secondsDecoded += secs
                    if line.contains("EMPTY (decoded to nothing)") {
                        d.utterancesEmpty += 1
                        d.secondsEmpty += secs
                    }
                    if let decode = double(in: line, before: "s depth") { d.decodeSecondsMax = max(d.decodeSecondsMax, decode) }
                    if let queued = double(in: line, after: "queued=") { d.queueSecondsMax = max(d.queueSecondsMax, queued) }
                }
            }
        }
        return d
    }

    // MARK: - The report

    /// Everything about the machine and the recording that helps, and nothing
    /// that identifies the meeting.
    struct Environment {
        var appVersion: String
        var build: String
        var system: String
        var hardware: String
        var memoryGB: Int

        static func current() -> Environment {
            let info = Bundle.main.infoDictionary
            let os = ProcessInfo.processInfo.operatingSystemVersion
            var machine = "unknown"
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            if size > 0 {
                var buffer = [CChar](repeating: 0, count: size)
                sysctlbyname("hw.model", &buffer, &size, nil, 0)
                machine = String(cString: buffer)
            }
            #if arch(arm64)
            let arch = "Apple silicon"
            #else
            let arch = "Intel"
            #endif
            return Environment(
                appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
                build: info?["CFBundleVersion"] as? String ?? "?",
                system: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                hardware: "\(machine) (\(arch))",
                memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
        }
    }

    /// The exact text that gets sent — rendered in full in the sheet first, so
    /// nothing about this is a matter of trust.
    static func text(description: String,
                     meeting: Meeting,
                     diagnostics d: Diagnostics?,
                     environment env: Environment,
                     attachingLog: Bool) -> String {
        var out = "Seal problem report\n===================\n\n"
        out += pair("App", "\(env.appVersion) (\(env.build))")
        out += pair("System", "\(env.system) · \(env.hardware) · \(env.memoryGB) GB")
        out += pair("Recording", String(format: "%.0f min · language %@ · %d lines",
                                        meeting.duration / 60, meeting.language, meeting.lines.count))

        out += "\nWhat went wrong\n---------------\n"
        let said = description.trimmingCharacters(in: .whitespacesAndNewlines)
        out += (said.isEmpty ? "(not described)" : said) + "\n"

        if let d {
            out += "\nTranscription diagnostics\n-------------------------\n"
            if !d.sessionLine.isEmpty { out += pair("Session", d.sessionLine) }
            out += pair("Utterances", utterancesLine(d))
            if d.utterancesSkipped > 0 { out += pair("Not attempted", "\(d.utterancesSkipped) (too little speech)") }
            if !d.segmentDrops.isEmpty { out += pair("Windows dropped", counts(d.segmentDrops)) }
            if !d.guardDrops.isEmpty { out += pair("Lines filtered", counts(d.guardDrops)) }
            if !d.votes.isEmpty { out += pair("Language", counts(d.votes)) }
            if d.detectionsOutsideAllowedSet > 0 {
                out += pair("Other languages", "\(d.detectionsOutsideAllowedSet) detections outside the allowed set")
            }
            if d.promptRetries > 0 || d.promptAbandoned {
                out += pair("Vocabulary", "\(d.promptRetries) decodes retried without the prompt"
                            + (d.promptAbandoned ? "; prompt abandoned" : ""))
            }
            if d.namesCorrected > 0 { out += pair("Names corrected", "\(d.namesCorrected)") }
            out += pair("Slowest decode", String(format: "%.1fs (longest queue wait %.1fs)",
                                                 d.decodeSecondsMax, d.queueSecondsMax))
            let trouble = [d.decodeErrors > 0 ? "\(d.decodeErrors) decode errors" : nil,
                           d.stalls > 0 ? "\(d.stalls) stalls" : nil].compactMap { $0 }
            out += pair("Errors", trouble.isEmpty ? "none" : trouble.joined(separator: ", "))
            if d.truncated { out += pair("Note", "the log hit its size limit and stops early") }
        } else {
            out += "\nTranscription diagnostics\n-------------------------\n"
            out += "No diagnostics log for this recording (it predates them, or was deleted).\n"
        }

        out += "\n"
        out += attachingLog
            ? "The full diagnostics log is attached. It quotes what was said.\n"
            : "No transcript text is included above, and no log is attached.\n"
        return out
    }

    private static func utterancesLine(_ d: Diagnostics) -> String {
        guard d.utterancesEmpty > 0 else {
            return String(format: "%d decoded (%.0fs of speech), all produced text",
                          d.utterancesDecoded, d.secondsDecoded)
        }
        return String(format: "%d decoded (%.0fs), %d produced NO text (%.0fs, %.0f%% of the speech)",
                      d.utterancesDecoded, d.secondsDecoded,
                      d.utterancesEmpty, d.secondsEmpty, d.emptyShare * 100)
    }

    // MARK: - Line reading

    private static func pair(_ label: String, _ value: String) -> String {
        label.padding(toLength: max(16, label.count + 1), withPad: " ", startingAt: 0) + value + "\n"
    }

    private static func counts(_ tally: [String: Int]) -> String {
        tally.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
    }

    /// "[Others] commit #36 …" / "[You] force-cut #4 …" -> a key for pairing
    /// the hand-over line with the one that reports what came back.
    ///
    /// Keyed on the stream and the utterance number only, never the marker: an
    /// utterance cut at the length cap is handed over as "force-cut #35" and
    /// returns as "commit #35". Including the marker silently failed to pair
    /// those, and force-cuts are long continuous speech — the utterances whose
    /// loss matters most.
    private static func commitKey(in line: String) -> String? {
        guard let stream = value(in: line, after: "[", upTo: "]") else { return nil }
        for marker in ["commit #", "force-cut #"] {
            if let number = value(in: line, after: marker, upTo: " ") { return stream + "#" + number }
        }
        return nil
    }

    /// The named guard that dropped a line, without the line it quotes.
    private static func dropKind(in line: String) -> String? {
        guard let range = line.range(of: "DROP ") else { return nil }
        let rest = line[range.upperBound...]
        // Everything up to the colon that introduces the quoted text, minus any
        // parenthesised numbers — so drops of the same kind tally together.
        let kind = rest.prefix { $0 != ":" && $0 != "(" }
        let trimmed = kind.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func value(in line: String, after prefix: String, upTo terminator: String) -> String? {
        guard let start = line.range(of: prefix) else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.range(of: terminator) else {
            return rest.isEmpty ? nil : String(rest)
        }
        let found = String(rest[..<end.lowerBound])
        return found.isEmpty ? nil : found
    }

    private static func double(in line: String, after prefix: String) -> Double? {
        guard let start = line.range(of: prefix) else { return nil }
        let digits = line[start.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    /// The number immediately before a marker: "decode=1.1s depth=1" -> 1.1.
    private static func double(in line: String, before marker: String) -> Double? {
        guard let end = line.range(of: marker) else { return nil }
        let digits = String(line[..<end.lowerBound].reversed().prefix { $0.isNumber || $0 == "." }.reversed())
        return Double(digits)
    }
}
