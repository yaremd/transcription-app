#!/usr/bin/env swift
//
// Seeds an isolated Seal library with invented meetings, for marketing
// screenshots and manual QA.
//
//   swift scripts/seed-demo.swift ~/SealDemo
//   SEAL_DEMO_CONTAINER=~/SealDemo open -n .build/…/Seal.app     (Debug build)
//
// Everything below is fiction. The point of the container is that no real
// meeting is ever read, moved, or overwritten — see Sources/DemoMode.swift.
// The script refuses to write anywhere near the real library.

import Foundation

// MARK: - Shapes (mirroring Sources/Meeting.swift)

struct StoredLine: Codable {
    var id = UUID()
    var speaker: String
    var text: String
    var at: Date?
    var start: TimeInterval?
    var end: TimeInterval?
}

struct NoteBlock: Codable {
    var id = UUID()
    var text: String
    var at: Date
}

struct ActionItem: Codable {
    var id = UUID()
    var text: String
    var done: Bool = false
}

struct Meeting: Codable {
    var id = UUID()
    var title: String
    var date: Date
    var duration: TimeInterval
    var language: String
    var lines: [StoredLine]
    var notes: String
    var userNotes: String?
    var noteBlocks: [NoteBlock]?
    var tags: [String]?
    var folder: String?
    var actionItems: [ActionItem]?
    var speakerNames: [String: String]?
}

// MARK: - Destination, guarded

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/seed-demo.swift <container-dir>\n".data(using: .utf8)!)
    exit(2)
}
let container = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath,
                    isDirectory: true).standardizedFileURL

let fm = FileManager.default
let realLibrary = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Seal", isDirectory: true).standardizedFileURL

// Refuse to seed into (or anywhere under) the real library. This script writes
// files unattended; a mistyped path must fail loudly, not quietly shred a
// meeting archive.
if container.path == realLibrary.path || container.path.hasPrefix(realLibrary.path + "/") {
    FileHandle.standardError.write(
        "refusing to seed inside the real library at \(realLibrary.path)\npick a throwaway directory instead\n".data(using: .utf8)!)
    exit(1)
}

let meetingsDir = container.appendingPathComponent("Meetings", isDirectory: true)
try fm.createDirectory(at: meetingsDir, withIntermediateDirectories: true)

// MARK: - Content

let cal = Calendar.current
func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
    let day = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
    return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
}
/// Builds a transcript, spacing lines a few seconds apart from the start.
func transcript(_ start: Date, _ pairs: [(String, String)]) -> [StoredLine] {
    var t: TimeInterval = 4
    return pairs.map { speaker, text in
        let line = StoredLine(speaker: speaker, text: text,
                              at: start.addingTimeInterval(t), start: t, end: t + 5.5)
        t += Double(max(4, text.count / 12)) + 3
        return line
    }
}

let weeklySyncStart = at(0, 14, 0)
let weeklySync = Meeting(
    title: "Weekly sync — Ardith × Vale",
    date: weeklySyncStart,
    duration: 12 * 60 + 38,
    language: "en",
    lines: transcript(weeklySyncStart, [
        ("Ines", "Before we wrap — can we lock the launch date?"),
        ("You", "Thursday works, if the build passes QA tomorrow."),
        ("Ines", "Perfect. Then ad spend holds until launch week."),
        ("You", "Deal. I'll get QA on it first thing."),
        ("Ines", "One more — who's writing the pricing page copy?"),
        ("You", "You take the first pass, I'll edit. Friday?"),
        ("Ines", "Friday's fine. I'll send it over Thursday night."),
    ]),
    notes: """
    ## Launch
    - Shipping **Thursday**, conditional on tomorrow's QA pass.
    - Ad spend holds until launch week — no spend before the build is green.

    ## Pricing page
    - Ines drafts the copy, sends Thursday evening.
    - You edit Friday.
    """,
    userNotes: "launch thurs — QA gate\npricing copy: Ines drafts, I edit",
    noteBlocks: [
        NoteBlock(text: "launch thurs — QA gate", at: weeklySyncStart.addingTimeInterval(140)),
        NoteBlock(text: "[ ] pricing copy: Ines drafts, I edit", at: weeklySyncStart.addingTimeInterval(520)),
    ],
    tags: ["launch", "vale"],
    folder: "Vale",
    actionItems: [
        ActionItem(text: "Run QA on the release build first thing tomorrow"),
        ActionItem(text: "Edit the pricing page copy once Ines sends the draft"),
        ActionItem(text: "Hold ad spend until the build is green", done: true),
    ],
    speakerNames: ["Others": "Ines"]
)

let designStart = at(0, 10, 30)
let designReview = Meeting(
    title: "Design review — onboarding",
    date: designStart,
    duration: 26 * 60 + 4,
    language: "en",
    lines: transcript(designStart, [
        ("Teodor", "The model download is the whole first impression right now."),
        ("You", "Agreed. It should say what it's doing and how long that takes."),
        ("Teodor", "Real percentages, not a spinner. People forgive a wait they can see."),
        ("You", "Let's show the size up front too — a gigabyte is worth warning about."),
    ]),
    notes: """
    ## Onboarding
    - The first-run model download **is** the first impression; treat it as a screen, not a wait.
    - Show real progress and the download size rather than an indeterminate spinner.
    """,
    userNotes: "download = first impression\nreal % + size up front",
    noteBlocks: nil,
    tags: ["design"],
    folder: nil,
    actionItems: [ActionItem(text: "Put real percentages and the model size on the first-run screen")],
    speakerNames: ["Others": "Teodor"]
)

let oneOnOneStart = at(1, 9, 15)
let oneOnOne = Meeting(
    title: "1:1 with Ines",
    date: oneOnOneStart,
    duration: 31 * 60 + 12,
    language: "en",
    lines: transcript(oneOnOneStart, [
        ("Ines", "How did the Vale call land on your side?"),
        ("You", "Better than I expected. They want the migration done before the quarter closes."),
        ("Ines", "That's tight. What would you cut to make it?"),
        ("You", "The bulk importer. Nobody's asked for it twice."),
    ]),
    notes: """
    ## Vale
    - They want the migration finished before quarter close — tight but not impossible.
    - Candidate to cut: the bulk importer. Low demand, high cost.
    """,
    userNotes: nil, noteBlocks: nil,
    tags: ["1:1"], folder: "Vale",
    actionItems: [ActionItem(text: "Scope the migration without the bulk importer")],
    speakerNames: ["Others": "Ines"]
)

let standupStart = at(2, 9, 0)
let standup = Meeting(
    title: "Sprint planning",
    date: standupStart,
    duration: 18 * 60 + 47,
    language: "en",
    lines: transcript(standupStart, [
        ("Teodor", "Two things carried over: the microphone picker and the folder rules."),
        ("You", "Picker's done, it just needs the Bluetooth case tested."),
    ]),
    notes: """
    ## Carried over
    - Microphone picker — code complete, Bluetooth path still untested.
    - Folder rules — not started.
    """,
    userNotes: nil, noteBlocks: nil,
    tags: nil, folder: nil,
    actionItems: [ActionItem(text: "Test the microphone picker against a Bluetooth headset")],
    speakerNames: ["Others": "Teodor"]
)

// MARK: - Write

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601

let all = [weeklySync, designReview, oneOnOne, standup]
for meeting in all {
    let url = meetingsDir.appendingPathComponent("\(meeting.id.uuidString).json")
    try encoder.encode(meeting).write(to: url, options: .atomic)
}

print("seeded \(all.count) meetings into \(meetingsDir.path)")
print("launch with:  SEAL_DEMO_CONTAINER=\(container.path) <Debug>/Seal.app/Contents/MacOS/Seal")
