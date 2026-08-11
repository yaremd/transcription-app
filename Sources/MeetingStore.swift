import Foundation
import Combine

/// Loads and saves meetings as individual JSON files in
/// ~/Library/Application Support/Seal/Meetings — one file per meeting.
/// The data is transparent (plain JSON the user can inspect or back up) and
/// never leaves the Mac. For personal use the whole set is small enough to keep
/// in memory, so `meetings` is the single source of truth the UI observes.
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    /// Meetings whose far-side voices are being identified right now — the
    /// detail view shows progress and keeps the button from double-running.
    @Published var identifyingSpeakers: Set<UUID> = []

    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Seal/Meetings", isDirectory: true)
        let legacy = base.appendingPathComponent("LocalScribe/Meetings", isDirectory: true)

        // One-time move for the 2026 LocalScribe → Seal rename: relocate the whole
        // meetings folder (JSON + its sibling audio) to the new location. A single
        // atomic directory move — and if it can't complete, we fall back to the
        // legacy folder so meetings are never lost. Runs only until it succeeds
        // (once the new folder exists, this is skipped).
        var resolved = dir
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.createDirectory(at: base.appendingPathComponent("Seal", isDirectory: true),
                                    withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: legacy, to: dir)
            } catch {
                NSLog("MeetingStore: LocalScribe→Seal migration failed, keeping legacy folder — \(error.localizedDescription)")
                resolved = legacy
            }
        }
        directory = resolved
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    /// Reads every saved meeting from disk, newest first.
    func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        meetings = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Meeting.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    /// Creates or updates a meeting (keyed by id) and writes it to disk atomically.
    func save(_ meeting: Meeting) {
        do {
            let data = try encoder.encode(meeting)
            try data.write(to: fileURL(for: meeting.id), options: .atomic)
            if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
                meetings[idx] = meeting
            } else {
                meetings.append(meeting)
            }
            meetings.sort { $0.date > $1.date }
        } catch {
            NSLog("MeetingStore: save failed — \(error.localizedDescription)")
        }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: fileURL(for: meeting.id))
        try? FileManager.default.removeItem(at: diagnosticsURL(for: meeting.id))
        deleteAudio(for: meeting.id)
        meetings.removeAll { $0.id == meeting.id }
    }

    // MARK: - Meeting audio (sibling .m4a files, written only when the user
    // keeps meeting audio on; they enable "Improve transcript")

    func audioURL(for id: UUID, stream: String) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(stream).m4a")
    }

    /// Where this meeting's transcription decision trail is written. Sits next
    /// to the audio so a bug report is the files beside one meeting.
    func diagnosticsURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).diag.log")
    }

    /// The meeting's saved audio files that actually exist on disk.
    func existingAudioURLs(for id: UUID) -> (mic: URL?, system: URL?) {
        let mic = audioURL(for: id, stream: "mic")
        let system = audioURL(for: id, stream: "system")
        let fm = FileManager.default
        return (fm.fileExists(atPath: mic.path) ? mic : nil,
                fm.fileExists(atPath: system.path) ? system : nil)
    }

    func hasAudio(for id: UUID) -> Bool {
        let urls = existingAudioURLs(for: id)
        return urls.mic != nil || urls.system != nil
    }

    func deleteAudio(for id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(for: id, stream: "mic"))
        try? FileManager.default.removeItem(at: audioURL(for: id, stream: "system"))
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
