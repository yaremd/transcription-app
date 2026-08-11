import Foundation
import FluidAudio

/// One stretch of one far-side voice, on the system-audio timeline.
struct SpeakerTurn: Equatable {
    let speaker: String        // "S1", "S2", … — S1 talks the most
    let start: TimeInterval    // seconds into the system-audio recording
    let end: TimeInterval
}

/// Tells the far side's voices apart in a finished meeting's saved system
/// audio, so eight people stop being one "Others".
///
/// Runs pyannote-style diarization (segmentation + speaker embeddings + VBx
/// clustering) via FluidAudio's Core ML models — on the Neural Engine, on
/// device, like everything else in Seal. The models are fetched once into
/// `~/Library/Application Support/FluidAudio/Models` (Application Support on
/// purpose: Whisper models once went to ~/Documents and synced to iCloud) and
/// work offline from then on.
///
/// This is deliberately post-hoc: it reads the finished recording rather than
/// chasing the live stream. Offline clustering sees the whole meeting at once,
/// which is what lets it decide "these two stretches are the same voice" —
/// the live view keeps its honest You/Others, and the labels arrive with the
/// notes, moments after Stop.
enum SpeakerLabeler {

    /// Whether the diarization models are already on this machine — when they
    /// are, labeling can be offered even with no network. Judged by the model
    /// directory having real content; `prepareModels` remains the authority
    /// and re-fetches anything missing.
    static func modelsReady() -> Bool {
        let dir = OfflineDiarizerModels.defaultModelsDirectory()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return !contents.isEmpty
    }

    /// Identifies the voices in the recording at `url`. First call downloads
    /// the models (~tens of MB, one-time); everything after is local.
    ///
    /// `clusteringThreshold` overrides the pipeline's default (0.6): the
    /// Euclidean distance under which two voices count as the same person.
    /// Lower splits more readily.
    static func turns(inSystemAudioAt url: URL,
                      clusteringThreshold: Double? = nil) async throws -> [SpeakerTurn] {
        var config = OfflineDiarizerConfig.default
        if let threshold = clusteringThreshold { config.clustering.threshold = threshold }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(url)
        return normalized(result.segments.map {
            (id: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        })
    }

    // MARK: - The whole job, for one saved meeting

    /// Identifies the far side's voices in a saved meeting and writes them
    /// onto its lines. Returns a sentence for the UI when something prevents
    /// it, nil on success. Publishes progress via `store.identifyingSpeakers`.
    ///
    /// New meetings carry per-line audio offsets and match exactly; meetings
    /// from before those existed are aligned through their wall-clock commit
    /// dates instead (see `labelLegacy`).
    @MainActor
    static func identify(meetingID: UUID, store: MeetingStore) async -> String? {
        guard let meeting = store.meetings.first(where: { $0.id == meetingID }) else { return nil }
        guard let systemURL = store.existingAudioURLs(for: meetingID).system else {
            return "This meeting has no saved call audio to identify voices in."
        }
        guard meeting.lines.contains(where: { $0.speaker == "Others" }) else {
            return "No far-side lines to label."
        }
        guard !store.identifyingSpeakers.contains(meetingID) else { return nil }
        store.identifyingSpeakers.insert(meetingID)
        defer { store.identifyingSpeakers.remove(meetingID) }

        do {
            let turns = try await turns(inSystemAudioAt: systemURL)
            // Re-fetch: the meeting may have changed while the model ran.
            guard var updated = store.meetings.first(where: { $0.id == meetingID }) else { return nil }
            var lines = updated.lines
            let hasOffsets = lines.contains { $0.speaker == "Others" && $0.start != nil }
            let labeled = hasOffsets
                ? label(&lines, with: turns)
                : labelLegacy(&lines, with: turns, meetingStart: updated.date)
            guard labeled > 0 else {
                return "Couldn't match the voices back to the transcript."
            }
            updated.lines = lines
            store.save(updated)
            return nil
        } catch {
            return "Speaker identification didn't finish: \(error.localizedDescription)"
        }
    }

    // MARK: - Matching turns to transcript lines

    /// The voice that owns a line's span: whichever speaker holds the most of
    /// [start, end], or — when the diarizer heard no speech there at all (its
    /// gates and Whisper's disagree at the margins) — the nearest turn within
    /// `reach` seconds. nil means "leave the line unlabeled" and is always
    /// preferred over a guess.
    static func voice(from start: TimeInterval, to end: TimeInterval,
                      in turns: [SpeakerTurn], reach: TimeInterval = 3.0) -> String? {
        guard end > start else { return nil }
        var overlap: [String: TimeInterval] = [:]
        var nearest: (speaker: String, gap: TimeInterval)?
        for turn in turns {
            let shared = min(end, turn.end) - max(start, turn.start)
            if shared > 0 {
                overlap[turn.speaker, default: 0] += shared
            } else {
                let gap = max(turn.start - end, start - turn.end)
                if nearest == nil || gap < nearest!.gap { nearest = (turn.speaker, gap) }
            }
        }
        if let best = overlap.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            return best.key
        }
        if let nearest, nearest.gap <= reach { return nearest.speaker }
        return nil
    }

    /// Labels a saved transcript's far-side lines with the voices heard in
    /// the system audio. Lines from the mic ("You") are never touched; far
    /// lines the diarizer can't place keep a nil voice rather than a guess.
    /// Returns how many lines were labeled, for the diagnostics log.
    static func label(_ lines: inout [StoredLine], with turns: [SpeakerTurn],
                      farSpeaker: String = "Others") -> Int {
        guard !turns.isEmpty else { return 0 }
        var labeled = 0
        for index in lines.indices where lines[index].speaker == farSpeaker {
            guard let start = lines[index].start, let end = lines[index].end,
                  let voice = voice(from: start, to: end, in: turns) else { continue }
            lines[index].voice = voice
            labeled += 1
        }
        return labeled
    }

    /// The far-side voices a labeled transcript actually uses, in S-number
    /// order. One voice means the far side was one person — the UI shows the
    /// plain label and no chips.
    static func voices(in lines: [StoredLine]) -> [String] {
        var seen: Set<String> = []
        for line in lines { if let v = line.voice { seen.insert(v) } }
        return seen.sorted { lhs, rhs in
            (Int(lhs.dropFirst()) ?? 0, lhs) < (Int(rhs.dropFirst()) ?? 0, rhs)
        }
    }

    /// Old meetings carry wall-clock commit dates but no audio offsets. The
    /// wall clock and the recording's clock differ by an unknown lead (model
    /// load before capture, and any pauses). A line starts *inside* a stretch
    /// of speech, so the shift is estimated from how far each line's
    /// wall-clock position sits outside the nearest diarizer turn — zero when
    /// it's already inside one — and the median keeps a few stragglers from
    /// steering it. Majority overlap is then required; the nearest-turn
    /// fallback is not extended to estimated positions.
    static func labelLegacy(_ lines: inout [StoredLine], with turns: [SpeakerTurn],
                            meetingStart: Date, farSpeaker: String = "Others") -> Int {
        guard !turns.isEmpty else { return 0 }
        let dated = lines.enumerated().filter { $0.element.speaker == farSpeaker && $0.element.at != nil }
        guard dated.count >= 3 else { return 0 }

        var disagreements: [TimeInterval] = []
        for (_, line) in dated {
            let wallOffset = line.at!.timeIntervalSince(meetingStart)
            // Signed distance to the nearest turn: 0 inside, positive when the
            // wall clock has run ahead of the audio (the common case).
            var nearest: TimeInterval?
            for turn in turns {
                let distance: TimeInterval
                if wallOffset < turn.start { distance = wallOffset - turn.start }
                else if wallOffset > turn.end { distance = wallOffset - turn.end }
                else { distance = 0 }
                if nearest == nil || abs(distance) < abs(nearest!) { nearest = distance }
                if distance == 0 { break }
            }
            if let nearest { disagreements.append(nearest) }
        }
        guard !disagreements.isEmpty else { return 0 }
        let shift = disagreements.sorted()[disagreements.count / 2]

        var labeled = 0
        for (index, line) in dated {
            let start = line.at!.timeIntervalSince(meetingStart) - shift
            // A commit date marks the utterance's start; its length is unknown.
            // Six seconds covers the typical utterance without spilling far
            // into a neighbour's turn.
            guard let voice = voice(from: start, to: start + 6, in: turns, reach: 0) else { continue }
            lines[index].voice = voice
            labeled += 1
        }
        return labeled
    }

    /// Maps the model's arbitrary cluster ids to "S1", "S2", … ordered by
    /// total talk time, so the biggest voice in the room is always S1 and two
    /// runs over the same audio read the same way.
    static func normalized(_ raw: [(id: String, start: TimeInterval, end: TimeInterval)]) -> [SpeakerTurn] {
        var talk: [String: TimeInterval] = [:]
        for turn in raw { talk[turn.id, default: 0] += turn.end - turn.start }
        let ranked = talk.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
        let names = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, "S\($0 + 1)") })
        return raw
            .compactMap { turn -> SpeakerTurn? in
                guard turn.end > turn.start, let name = names[turn.id] else { return nil }
                return SpeakerTurn(speaker: name, start: turn.start, end: turn.end)
            }
            .sorted { $0.start < $1.start }
    }
}
