import Foundation
import EventKit

/// What a calendar event contributes to a recording (YAR-36, Pro): its title
/// and who was invited.
struct CalendarEventContext: Equatable {
    var title: String
    var attendees: [String]
}

/// Opt-in, read-only calendar context. Consulted exactly once, at the moment
/// a recording starts; access is requested from the Settings toggle, never
/// mid-recording. Like everything else, what it reads never leaves the Mac.
enum CalendarContext {

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// The Settings toggle's flow: ask macOS for read access.
    static func requestAccess() async -> Bool {
        if hasAccess { return true }
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The event this recording belongs to, if any.
    static func currentEvent(at now: Date = Date()) -> CalendarEventContext? {
        guard hasAccess else { return nil }
        let store = EKEventStore()
        // A meeting can already be hours old when the user starts recording
        // late, so look back generously and only a little forward.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600),
                                                 end: now.addingTimeInterval(600),
                                                 calendars: nil)
        let candidates = store.events(matching: predicate).map { event in
            Candidate(title: event.title ?? "",
                      start: event.startDate ?? now,
                      end: event.endDate ?? now,
                      isAllDay: event.isAllDay,
                      attendees: (event.attendees ?? []).compactMap(\.name))
        }
        return pick(from: candidates, at: now)
    }

    // MARK: - The choice, pure and testable

    struct Candidate {
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var attendees: [String]
    }

    /// Which event a recording started at `now` belongs to:
    /// - all-day events never count — they are context, not meetings;
    /// - an event *covering* now wins, and the shortest covering event wins
    ///   outright (the 30-minute standup inside a week-long offsite is the
    ///   meeting being recorded, not the offsite);
    /// - with nothing covering, an event about to start (within 10 minutes)
    ///   is the meeting — people hit record early;
    /// - otherwise there is no calendar context, and that must stay nil —
    ///   naming a recording after a meeting that ended an hour ago is worse
    ///   than no name.
    static func pick(from candidates: [Candidate], at now: Date) -> CalendarEventContext? {
        let real = candidates.filter {
            !$0.isAllDay && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let covering = real
            .filter { $0.start <= now && $0.end > now }
            .min { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }
        let upcoming = real
            .filter { $0.start > now && $0.start.timeIntervalSince(now) <= 600 }
            .min { $0.start < $1.start }
        guard let event = covering ?? upcoming else { return nil }
        var seen = Set<String>()
        let attendees = event.attendees
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return CalendarEventContext(title: event.title.trimmingCharacters(in: .whitespaces),
                                    attendees: Array(attendees.prefix(12)))
    }
}
