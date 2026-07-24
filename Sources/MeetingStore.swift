import Foundation
import Combine

/// Loads and saves meetings as individual JSON files in
/// ~/Library/Application Support/LocalScribe/Meetings — one file per meeting.
/// The data is transparent (plain JSON the user can inspect or back up) and
/// never leaves the Mac. For personal use the whole set is small enough to keep
/// in memory, so `meetings` is the single source of truth the UI observes.
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []

    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("LocalScribe/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
        deleteAudio(for: meeting.id)
        meetings.removeAll { $0.id == meeting.id }
    }

    // MARK: - Meeting audio (sibling .m4a files, written only when the user
    // keeps meeting audio on; they enable "Improve transcript")

    func audioURL(for id: UUID, stream: String) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(stream).m4a")
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
