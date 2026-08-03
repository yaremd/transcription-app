import Foundation
import Combine

struct TranscriptLine: Identifiable {
    var id = UUID()
    let speaker: String
    /// The utterances making up this turn, in speaking order. Kept apart so an
    /// echo ghost can be pulled back out of a merged turn without taking the
    /// rest of the turn with it.
    var fragments: [String]
    /// When the speech started, from the capture stream's own audio clock —
    /// not when transcription finished. This is what orders the mic and system
    /// streams against each other, and the anchor notes link to.
    let at: Date
    /// When the speech ended; decides whether the speaker's next utterance
    /// continues this turn or starts a new one.
    var end: Date

    var text: String { fragments.joined(separator: " ") }
}

extension Array where Element == TranscriptLine {
    /// Places an utterance where it was spoken and returns the id of the line
    /// it landed in.
    ///
    /// Two jobs the live path used to do neither of. Order comes from the
    /// audio clock rather than from decode-completion order — the mic and
    /// system streams transcribe independently, so a long utterance routinely
    /// finishes after a short one that came later, and appending as results
    /// arrived put replies ahead of the lines they answered. And an utterance
    /// that simply continues the speaker's turn (the stream cuts one at every
    /// 0.85 s pause) is merged into it, so a paragraph reads as a paragraph
    /// instead of nine consecutive one-line turns — up to `characterCap`,
    /// past which a barely-pausing speaker starts a fresh one.
    mutating func place(speaker: String, text: String, timing: UtteranceTiming,
                        mergeGap: TimeInterval, characterCap: Int) -> UUID {
        // Usually an append: the scan starts at the end and stops at the first
        // line no later than this one.
        let insertAt = (lastIndex { $0.at <= timing.start }).map { $0 + 1 } ?? 0
        let previous = insertAt - 1
        if previous >= 0, previous < count,
           self[previous].speaker == speaker,
           timing.start.timeIntervalSince(self[previous].end) <= mergeGap,
           self[previous].text.count < characterCap {
            self[previous].fragments.append(text)
            self[previous].end = Swift.max(self[previous].end, timing.end)
            return self[previous].id
        }
        let line = TranscriptLine(speaker: speaker, fragments: [text],
                                  at: timing.start, end: timing.end)
        insert(line, at: insertAt)
        return line.id
    }
}

enum TranscriptLanguage: String, CaseIterable, Identifiable {
    case ukrainian
    case english
    case auto

    var id: String { rawValue }

    /// ISO code Whisper expects; nil = auto-detect.
    var code: String? {
        switch self {
        case .ukrainian: return "uk"
        case .english: return "en"
        case .auto: return nil
        }
    }

    /// Languages auto-detect may choose between. Left unrestricted, Whisper
    /// picks from 99 languages and mis-hears accented speech as Malay or
    /// Korean — then translates into it. Auto means "Ukrainian or English",
    /// matching what this picker offers. Ukrainian first: when nothing is
    /// known yet it romanizes less than a wrong English guess.
    var allowedCodes: [String] {
        switch self {
        case .ukrainian: return ["uk"]
        case .english: return ["en"]
        case .auto: return ["uk", "en"]
        }
    }

    var label: String {
        switch self {
        case .ukrainian: return "Ukrainian"
        case .english: return "English"
        case .auto: return "Auto-detect"
        }
    }

    /// How to instruct the notes model to write.
    var notesHint: String {
        switch self {
        case .ukrainian: return "Ukrainian"
        case .english: return "English"
        case .auto: return "the same language as the transcript"
        }
    }
}

enum TranscriptionSpeed: String, CaseIterable, Identifiable {
    case fast
    case accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "Fast"
        case .accurate: return "Accurate"
        }
    }

    /// Model preference order. Fast favors OpenAI's large-v3-turbo (v20240930,
    /// a 4-decoder-layer distillation — several times faster to decode than
    /// full large-v3 with nearly the same quality); Accurate favors full
    /// large-v3. Note "large-v3_turbo" is NOT the turbo model — it's full
    /// large-v3 in a different compilation. All are multilingual; "small" is a
    /// last resort.
    var modelCandidates: [String] {
        switch self {
        case .fast: return ["large-v3-v20240930_turbo", "large-v3-v20240930", "large-v3_turbo", "small"]
        case .accurate: return ["large-v3", "large-v3_turbo", "small"]
        }
    }
}

/// Mic/system level meters, isolated from AudioMonitor so their ~30 Hz updates
/// only re-render the meter bars — not the whole recording view with the
/// growing transcript in it.
final class AudioLevels: ObservableObject {
    @Published var mic: Float = 0
    @Published var system: Float = 0
}

/// Coordinates capture + on-device transcription for both the mic ("You") and
/// system audio ("Others"), plus local-LLM notes generation. Publishes
/// everything the UI needs. All @Published mutations happen on the main thread.
final class AudioMonitor: ObservableObject {
    @Published var isRunning = false
    @Published var isPaused = false
    /// When the current recording started — drives the live elapsed timer.
    /// nil when not recording. Set once per session, so watching it never
    /// re-renders anything on a per-second cadence.
    @Published var recordingStart: Date?
    @Published var statusMessage = "Press Start. You and the call will both be transcribed."
    @Published var modelStatus = ""
    @Published var errorMessage: String?
    /// Soft mic conditions (echo-cancellation restart, quiet input) — shown as
    /// a caption by the recording controls, separate from hard errors.
    @Published var noticeMessage: String?
    @Published var transcript: [TranscriptLine] = []
    @Published var liveLines: [String: String] = [:]
    /// Set when Stop saves a meeting — the UI navigates to it and clears this.
    @Published var finishedMeetingID: UUID?
    let levels = AudioLevels()
    private var liveUtterance: [String: Int] = [:]   // which utterance each live line shows
    @Published var language: TranscriptLanguage = .auto {
        didSet {
            let lang = language
            Task { await transcriber.setLanguagePolicy(forced: lang.code, allowed: lang.allowedCodes) }
        }
    }
    @Published var speed: TranscriptionSpeed = .fast {
        didSet { Task { await transcriber.reset() } }   // reload the matching model on next Start
    }

    // Notes (Stage 3)
    @Published var notes: String = ""
    @Published var isGeneratingNotes = false
    @Published var notesError: String?

    // Human-in-the-loop rough notes + selected template (Stage 4).
    // Notes are timestamped blocks so each one anchors to the moment of the
    // conversation it was written in.
    @Published var noteBlocks: [NoteBlock] = []
    @Published var template: NotesTemplate = .general

    /// The notes as plain text — what generation prompts and exports consume.
    var joinedNotes: String {
        noteBlocks.map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    /// Appends a note block stamped with the current moment.
    func addNoteBlock(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        noteBlocks.append(NoteBlock(text: trimmed, at: Date()))
    }

    func deleteNoteBlock(_ id: UUID) {
        noteBlocks.removeAll { $0.id == id }
    }

    /// Describes where notes are generated, for the UI.
    var notesEngineLabel: String {
        settings.usingCloudNotes ? "your cloud model" : "on-device AI"
    }

    // Persistence — hands finished sessions to the on-disk MeetingStore.
    private let store: MeetingStore
    private let vocabulary: VocabularyStore
    private let settings: AppSettings
    private var sessionStart = Date()
    private var sessionEnd = Date()
    private var currentMeetingID = UUID()
    private var discarding = false
    private var titlingMeetingID: UUID?   // meeting with an auto-title request in flight

    /// Below this much RAM the speech and notes models are kept from being
    /// resident at once (they run at different times — recording vs. post-meeting
    /// notes); at or above it, both stay loaded for speed.
    private static let bothModelsRAMFloor: UInt64 = 16 * 1_073_741_824   // 16 GB

    init(store: MeetingStore, vocabulary: VocabularyStore, settings: AppSettings) {
        self.store = store
        self.vocabulary = vocabulary
        self.settings = settings
        // On memory-tight Macs, free the speech model before the notes model
        // loads. The hook runs at each notes-model load and no-ops unless Whisper
        // is genuinely idle (not recording, and settled after the last meeting).
        if ProcessInfo.processInfo.physicalMemory < Self.bothModelsRAMFloor {
            let t = transcriber
            Task { await MLXEngine.shared.setPreLoadHook { await t.releaseIfIdle(minIdle: 3) } }
        }
    }

    private let speakerYou = "You"
    private let speakerOthers = "Others"

    /// Echo guard: with the raw mic (no echo cancellation), call audio played
    /// through speakers reaches the mic too, so the other side's phrase can
    /// land twice — once as "Others", once as a ghost "You". Committed lines
    /// are remembered briefly; a "You" line that closely matches a recent
    /// "Others" line is dropped, and when the "Others" copy arrives *after*
    /// the ghost, the already-shown ghost is removed retroactively.
    private struct RecentCommit {
        let id = UUID()
        let speaker: String
        let normalized: String
        /// The utterance exactly as committed, so it can be pulled back out of
        /// a turn that has since merged other utterances into it.
        let fragment: String
        let at: Date
        let lineID: UUID
    }
    private var recentCommits: [RecentCommit] = []
    private let echoWindowSeconds: TimeInterval = 12

    /// A speaker's continuous turn reaches us as several utterances — the
    /// stream cuts one at every 0.85 s pause — and shown as separate lines it
    /// reads as stutter rather than speech. Utterances this close together are
    /// rejoined into one turn, the way the offline polisher already does.
    private let turnMergeGap: TimeInterval = 2.0
    /// …but a turn stops absorbing once it is this long, so a speaker who
    /// barely pauses still produces readable paragraphs instead of one wall.
    private let turnMergeCharacterCap = 600

    private let mic = MicCapturer()
    private let system = SystemAudioCapturer()
    private let transcriber = Transcriber()
    private let notesGenerator = NotesGenerator()
    private var micStream: TranscriptionStream?
    private var systemStream: TranscriptionStream?
    private var micRecorder: SessionAudioRecorder?
    private var systemRecorder: SessionAudioRecorder?
    /// This session's transcription decision trail, written next to the
    /// meeting. Always on: it is small, local, and the only thing that explains
    /// a session that went wrong in a way its audio doesn't reproduce.
    private var diagnosticsLog: DiagnosticsLog?
    private var micMeterLast = Date.distantPast
    private var systemMeterLast = Date.distantPast

    /// Seconds of plausible speech each channel has carried this session, and
    /// whether we have already ruled on the microphone.
    ///
    /// Only meaningful when `MicCapturer` substituted the Mac's own mic for a
    /// Bluetooth default. A substitute that hears nothing while the other side
    /// talks and talks is not a quiet room — it is the wrong microphone, and on
    /// 2026-08-03 that cost a whole meeting's worth of one speaker. Neither
    /// channel can tell on its own: the mic alone cannot distinguish a deaf
    /// device from a listener who says nothing, and the system channel alone
    /// says nothing about the mic. Together they can.
    ///
    /// Both counters are written from their own capture thread, so both live
    /// under one lock.
    private let voicedLock = NSLock()
    private var micVoicedSeconds = 0.0
    private var systemVoicedSeconds = 0.0
    private var micVerdictReached = false
    /// Level a real voice clears on a mic that is actually picking it up
    /// (−40 dBFS). The failing built-in mic spent 99.4% of the meeting below it.
    private static let plausibleSpeechLevel: Float = 0.01
    /// How much of the other side we listen to before doubting a substitute mic
    /// that has heard nothing. Long enough that a brief silence never triggers
    /// it, short enough to rescue most of the meeting.
    static let farSideSecondsBeforeDoubt = 90.0
    /// Speech the substitute must have caught in that time to keep the job.
    static let micSecondsThatProveItHears = 2.0

    /// Whether a substituted microphone has proved it cannot hear the user.
    ///
    /// Deliberately asymmetric. A quiet participant and a deaf microphone look
    /// identical on the mic channel alone, so the far side supplies the second
    /// opinion: a meeting where the other side has talked for a minute and a
    /// half is one where a working mic near a participant picks up *something*
    /// — a word, an "mhm", a chair. Getting this wrong in one direction costs
    /// playback fidelity until the recording stops; in the other it costs a
    /// whole speaker, permanently. So a couple of seconds is enough to keep the
    /// job, and we only ever doubt a device the user did not choose.
    static func substituteMicIsDeaf(farSideSeconds: Double, micSeconds: Double) -> Bool {
        farSideSeconds >= farSideSecondsBeforeDoubt && micSeconds < micSecondsThatProveItHears
    }

    /// Loads the transcription model in the background so the first ⌘N of the
    /// app run starts hearing immediately instead of behind a warm-up.
    func prewarmModel() {
        let candidates = speed.modelCandidates
        Task { [transcriber] in
            guard !(await transcriber.isLoaded) else { return }
            try? await transcriber.load(candidates: candidates)
        }
    }

    func toggle() { isRunning ? stop() : start() }

    func start() {
        errorMessage = nil
        noticeMessage = nil
        transcript = []
        liveLines = [:]
        liveUtterance = [:]
        recentCommits = []
        voicedLock.lock()
        micVoicedSeconds = 0
        systemVoicedSeconds = 0
        micVerdictReached = false
        voicedLock.unlock()
        notes = ""
        notesError = nil
        noteBlocks = []
        isPaused = false
        discarding = false
        sessionStart = Date()
        sessionEnd = sessionStart
        recordingStart = sessionStart
        currentMeetingID = UUID()
        levels.mic = 0
        levels.system = 0
        isRunning = true
        statusMessage = "Getting ready…"

        // Load (and warm up) the model BEFORE capturing, so the first phrase
        // isn't lost and the first transcription isn't slow. After the first
        // time in a session the model is already loaded, so this is instant.
        Task { [weak self] in
            guard let self else { return }
            if !(await self.transcriber.isLoaded) {
                await MainActor.run { self.modelStatus = "Preparing model (first run downloads + warms it up)…" }
                do {
                    try await self.transcriber.load(candidates: self.speed.modelCandidates)
                } catch {
                    await MainActor.run {
                        self.appendError("Model load failed: \(error.localizedDescription)")
                        self.modelStatus = ""
                        self.statusMessage = "Couldn't start."
                        self.isRunning = false
                    }
                    return
                }
            }
            await self.transcriber.beginSession()
            await self.transcriber.setLanguagePolicy(forced: self.language.code, allowed: self.language.allowedCodes)
            await self.transcriber.setVocabulary(self.vocabulary.terms)
            await MainActor.run {
                guard self.isRunning else { return }   // user pressed Stop while loading
                // Once capture is live the control bar itself is the proof —
                // a lingering "ready" message would just be noise.
                self.modelStatus = ""
                self.beginCapture()
            }
        }
    }

    private func beginCapture() {
        let diag = DiagnosticsLog(url: store.diagnosticsURL(for: currentMeetingID))
        diagnosticsLog = diag
        diag.write("session start — speed=\(speed.rawValue) language=\(language.rawValue) keepAudio=\(settings.keepAudio)")
        Task { [transcriber] in
            await transcriber.setDiagnostics { diag.write($0) }
        }

        micStream = makeStream(for: speakerYou)
        systemStream = makeStream(for: speakerOthers)

        // Keep the session's audio (locally, next to the meeting) so the
        // finished meeting can be re-transcribed with the accurate model.
        if settings.keepAudio {
            micRecorder = SessionAudioRecorder(url: store.audioURL(for: currentMeetingID, stream: "mic"))
            systemRecorder = SessionAudioRecorder(url: store.audioURL(for: currentMeetingID, stream: "system"))
        }

        mic.onSamples = { [weak self] samples in self?.handleMic(samples) }
        // Soft mic conditions (e.g. echo cancellation silenced the input and
        // capture restarted on the raw mic) go to the status line; hard ones
        // (no signal at all, with what to check) go to the error area.
        mic.onNotice = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                self.noticeMessage = message
                // A status line the user may not be looking at is not a record.
                // A mic that dropped out mid-meeting has to be readable off the
                // meeting afterwards, next to the audio it explains.
                self.diagnosticsLog?.write("mic: \(message)")
            }
        }
        mic.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.appendError(message)
                self?.diagnosticsLog?.write("mic ERROR: \(message)")
            }
        }
        system.onSamples = { [weak self] samples in self?.handleSystem(samples) }
        system.onError = { [weak self] message in
            DispatchQueue.main.async { self?.appendError(message) }
        }

        do {
            try mic.start()
        } catch {
            appendError("Microphone: \(error.localizedDescription)")
        }
        system.start()
        statusMessage = "Listening… speak, and play the call for the \"Others\" side."
    }

    func stop() {
        teardownCapture(flush: true)
        Task { await transcriber.endSession() }   // recording done — Whisper may be freed for notes once idle
        sessionEnd = Date()
        persistCurrentSession()
        statusMessage = transcript.isEmpty ? "Stopped." : "Saved to your library."
        autoTitleCurrentSession()
        if !transcript.isEmpty { finishedMeetingID = currentMeetingID }
    }

    /// Clears a finished session off the recording screen ("New Recording"
    /// always starts fresh — the session itself is already in the library).
    /// Rotating the meeting id reroutes any still-in-flight transcription or
    /// notes results into the stored meeting instead of the cleared screen.
    func resetFinishedSession() {
        guard !isRunning else { return }
        guard !transcript.isEmpty || !noteBlocks.isEmpty || !notes.isEmpty || !liveLines.isEmpty else { return }
        currentMeetingID = UUID()
        titlingMeetingID = nil
        transcript = []
        liveLines = [:]
        liveUtterance = [:]
        recentCommits = []
        notes = ""
        notesError = nil
        noteBlocks = []
        errorMessage = nil
        noticeMessage = nil
        statusMessage = "Press Start. You and the call will both be transcribed."
    }

    /// Names the finished session after its content ("New transcription" →
    /// e.g. "Q3 pricing and rollout plan"). Runs in the background and stays
    /// hands-off: it only ever replaces the placeholder title, so a name the
    /// user typed is never overwritten. Silent on failure (e.g. Ollama not
    /// running) — the placeholder simply remains.
    private func autoTitleCurrentSession() {
        let meetingID = currentMeetingID
        let text = transcript.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        guard text.count >= 80 else { return }   // too little content to name
        guard store.meetings.first(where: { $0.id == meetingID })?.title == Meeting.defaultTitle else { return }
        guard titlingMeetingID != meetingID else { return }   // one attempt at a time
        titlingMeetingID = meetingID
        let hint = language.notesHint
        // Titles are a quick job — run them on the light model, not the heavy
        // notes model, so a name appears fast.
        let backend: NotesBackend = settings.usingCloudNotes
            ? .cloudOpenAICompatible(baseURL: settings.cloudBaseURL, apiKey: settings.cloudAPIKey, model: settings.cloudModel)
            : .localEmbedded(model: settings.embeddedModelID)
        Task { [weak self] in
            guard let self else { return }
            let title = try? await self.notesGenerator.suggestTitle(transcript: text, languageHint: hint, backend: backend)
            await MainActor.run {
                self.titlingMeetingID = nil   // allow a retry if a late line re-triggers
                guard let title,
                      var meeting = self.store.meetings.first(where: { $0.id == meetingID }),
                      meeting.title == Meeting.defaultTitle else { return }
                meeting.title = title
                self.store.save(meeting)
            }
        }
    }

    /// Pause/resume without ending the session: the capture engines keep running
    /// but incoming audio is ignored while paused, so nothing is transcribed.
    /// Pausing finalizes whatever was just said, so the text lands immediately.
    func pauseResume() {
        guard isRunning else { return }
        isPaused.toggle()
        if isPaused {
            micStream?.flush()
            systemStream?.flush()
            levels.mic = 0
            levels.system = 0
            statusMessage = "Paused."
        } else {
            statusMessage = "Listening…"
        }
    }

    /// Abandon the current session: stop capture, delete anything already saved
    /// for it, and clear the transcript/notes. Nothing is persisted.
    func discard() {
        discarding = true
        let idToRemove = currentMeetingID
        teardownCapture(flush: false)
        if let existing = store.meetings.first(where: { $0.id == idToRemove }) {
            store.delete(existing)   // removes its audio too
        } else {
            store.deleteAudio(for: idToRemove)   // nothing persisted yet, but audio may be
        }
        transcript = []
        liveLines = [:]
        notes = ""
        noteBlocks = []
        statusMessage = "Discarded."
    }

    private func teardownCapture(flush: Bool) {
        isRunning = false   // set first so an in-flight model-load Task won't start capture
        isPaused = false
        mic.stop()
        system.stop()
        micRecorder?.finish()
        systemRecorder?.finish()
        micRecorder = nil
        systemRecorder = nil
        if flush {
            micStream?.flush()
            systemStream?.flush()
        }
        micStream = nil
        systemStream = nil
        levels.mic = 0
        levels.system = 0
        recordingStart = nil
        noticeMessage = nil
        // Detach the tap before closing, so a straggling final pass can't write
        // into a closed file. Closing is idempotent either way.
        let finished = diagnosticsLog
        diagnosticsLog = nil
        Task { [transcriber] in
            await transcriber.setDiagnostics(nil)
            finished?.write("session end")
            finished?.close()
        }
    }

    /// Sends the finished transcript to the local LLM and produces notes.
    func generateNotes() {
        let text = transcript
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        guard !text.isEmpty else {
            notesError = "There's no transcript to summarize yet."
            return
        }
        notes = ""
        notesError = nil
        isGeneratingNotes = true
        let hint = language.notesHint
        let jotted = joinedNotes
        let tmpl = template
        let backend: NotesBackend = settings.usingCloudNotes
            ? .cloudOpenAICompatible(baseURL: settings.cloudBaseURL, apiKey: settings.cloudAPIKey, model: settings.cloudModel)
            : .localEmbedded(model: settings.embeddedModelID)
        let meetingID = currentMeetingID
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.notesGenerator.generate(transcript: text, userNotes: jotted, template: tmpl, languageHint: hint, backend: backend)
                await MainActor.run {
                    self.isGeneratingNotes = false
                    if self.currentMeetingID == meetingID {
                        self.notes = result
                        self.persistCurrentSession()   // save the generated notes into the stored meeting
                    } else if var meeting = self.store.meetings.first(where: { $0.id == meetingID }) {
                        // The screen moved on to a new session meanwhile —
                        // the notes still belong to their meeting.
                        meeting.notes = result
                        self.store.save(meeting)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isGeneratingNotes = false
                    if self.currentMeetingID == meetingID { self.notesError = error.localizedDescription }
                }
            }
        }
    }

    /// Builds a Meeting from the current session and saves it (idempotent by id).
    /// Called after Stop, when a late transcript line arrives, and after notes are
    /// generated. Preserves an existing title/notes so a re-save never clobbers them.
    private func persistCurrentSession() {
        guard !transcript.isEmpty else { return }
        // Carry each line's commit time into the saved meeting — it's what lets
        // notes anchor to the transcript moment they were written in. Without
        // it every saved line has a nil timestamp and note→transcript jumps
        // have nothing to aim at.
        let lines = transcript.map { StoredLine(speaker: $0.speaker, text: $0.text, at: $0.at) }
        let existing = store.meetings.first { $0.id == currentMeetingID }
        let joined = joinedNotes
        let jottedToStore: String? = joined.isEmpty ? existing?.userNotes : joined
        let blocksToStore: [NoteBlock]? = noteBlocks.isEmpty ? existing?.noteBlocks : noteBlocks
        let meeting = Meeting(
            id: currentMeetingID,
            title: existing?.title ?? Meeting.defaultTitle,
            date: sessionStart,
            duration: max(0, sessionEnd.timeIntervalSince(sessionStart)),
            language: language.rawValue,
            lines: lines,
            notes: notes.isEmpty ? (existing?.notes ?? "") : notes,
            userNotes: jottedToStore,
            noteBlocks: blocksToStore,
            templateID: template.id,
            tags: existing?.tags,
            actionItems: existing?.actionItems)
        store.save(meeting)
    }

    private func makeStream(for speaker: String) -> TranscriptionStream {
        // The stream belongs to THIS session's meeting. If a slow final pass
        // lands after the screen was reset (or a new session started), its
        // line goes straight into the stored meeting, not the fresh screen.
        let sessionMeetingID = currentMeetingID
        let stream = TranscriptionStream(label: speaker) { [transcriber] samples, mode in
            await transcriber.transcribe(samples, source: speaker, mode: mode)
        }
        if let diagnosticsLog { stream.diagnostics = { diagnosticsLog.write($0) } }
        stream.onLive = { [weak self] id, text in
            DispatchQueue.main.async {
                guard let self, self.isRunning, !self.discarding,
                      self.currentMeetingID == sessionMeetingID else { return }
                self.liveLines[speaker] = text
                self.liveUtterance[speaker] = id
            }
        }
        stream.onCommit = { [weak self] id, text, timing in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.currentMeetingID == sessionMeetingID else {
                    // Straggler from a session no longer on screen.
                    if let text, !text.isEmpty {
                        self.appendToStoredMeeting(sessionMeetingID, speaker: speaker,
                                                   text: text, at: timing.start)
                    }
                    return
                }
                // Clear the live preview only if it still shows this utterance —
                // never wipe the preview of the next utterance already underway.
                if let shown = self.liveUtterance[speaker], shown <= id {
                    self.liveLines[speaker] = nil
                    self.liveUtterance[speaker] = nil
                }
                guard let text, !self.discarding else { return }   // silence, or dropped session
                self.commitLine(speaker: speaker, text: text, timing: timing)
                if !self.isRunning {
                    // A late line landed after Stop: save it, and (re)try the
                    // auto-title now that there is more/any content.
                    self.persistCurrentSession()
                    self.autoTitleCurrentSession()
                }
            }
        }
        return stream
    }

    /// Appends a straggler line to an already-saved meeting (no echo dedupe —
    /// by this point the session is closed and the line was worth keeping).
    private func appendToStoredMeeting(_ meetingID: UUID, speaker: String, text: String, at: Date) {
        guard var meeting = store.meetings.first(where: { $0.id == meetingID }) else { return }
        meeting.lines.append(StoredLine(speaker: speaker, text: text, at: at))
        store.save(meeting)
    }

    /// Places a final line in the transcript: at the moment it was spoken,
    /// merged into the speaker's turn when it continues one, and dropped
    /// outright when it is only the mic's echo of the call audio.
    private func commitLine(speaker: String, text: String, timing: UtteranceTiming) {
        let now = Date()
        recentCommits.removeAll { now.timeIntervalSince($0.at) > echoWindowSeconds }
        let normalized = AudioMonitor.normalizedForEcho(text)

        if speaker == speakerYou {
            // The call's phrase already landed as "Others"; this is its echo.
            let isGhost = recentCommits.contains {
                $0.speaker == speakerOthers && AudioMonitor.isEchoPair(normalized, $0.normalized)
            }
            if isGhost { return }
        } else {
            // The echo transcribed *faster* than the real thing: remove the
            // ghost "You" copy that is already on screen.
            let ghosts = recentCommits.filter {
                $0.speaker == speakerYou && AudioMonitor.isEchoPair(normalized, $0.normalized)
            }
            if !ghosts.isEmpty {
                ghosts.forEach(removeGhostFragment)
                let ghostIDs = Set(ghosts.map(\.id))
                recentCommits.removeAll { ghostIDs.contains($0.id) }
            }
        }

        let lineID = transcript.place(speaker: speaker, text: text, timing: timing,
                                      mergeGap: turnMergeGap, characterCap: turnMergeCharacterCap)
        recentCommits.append(RecentCommit(speaker: speaker, normalized: normalized,
                                          fragment: text, at: now, lineID: lineID))
    }

    /// Pulls one echoed utterance back out of the transcript. Its turn may have
    /// merged other utterances in since, so only the matching fragment goes —
    /// the line survives unless that fragment was all of it.
    private func removeGhostFragment(_ ghost: RecentCommit) {
        guard let index = transcript.firstIndex(where: { $0.id == ghost.lineID }) else { return }
        transcript[index].fragments.removeAll { $0 == ghost.fragment }
        if transcript[index].fragments.isEmpty { transcript.remove(at: index) }
    }

    /// Lowercased, punctuation-free, single-spaced text for echo comparison.
    static func normalizedForEcho(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True when two committed lines are almost certainly the same phrase heard
    /// twice. Requires enough words that ordinary short replies ("yes, yes",
    /// "thank you") are never deduplicated, then accepts containment or a high
    /// word-set overlap — the two transcriptions of one phrase rarely match
    /// verbatim.
    static func isEchoPair(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let wordsA = a.split(separator: " ")
        let wordsB = b.split(separator: " ")
        guard min(wordsA.count, wordsB.count) >= 4 else { return false }
        if a == b || a.contains(b) || b.contains(a) { return true }
        let setA = Set(wordsA)
        let setB = Set(wordsB)
        let overlap = Float(setA.intersection(setB).count)
        return overlap / Float(setA.union(setB).count) >= 0.85
    }

    private func handleMic(_ samples: [Float]) {
        if isPaused { return }
        micRecorder?.append(samples)
        let rms = AudioMonitor.rms(of: samples)
        if rms >= Self.plausibleSpeechLevel {
            voicedLock.lock()
            micVoicedSeconds += Double(samples.count) / 16_000
            voicedLock.unlock()
        }
        let now = Date()
        if now.timeIntervalSince(micMeterLast) > 0.033 {
            micMeterLast = now
            let level = AudioMonitor.displayLevel(rms)
            DispatchQueue.main.async { self.levels.mic = level }
        }
        micStream?.append(samples)
    }

    /// Decides whether a substituted microphone is earning its place. Runs on
    /// the main queue, where the capturer's device state is settled, and is
    /// triggered from the system-audio path because that is where the evidence
    /// accrues: the other side keeps talking and the mic keeps hearing nothing.
    private func judgeSubstituteMic(farSideSeconds: Double, micSeconds: Double) {
        guard isRunning, mic.substitutedForBluetooth else { return }
        let deaf = Self.substituteMicIsDeaf(farSideSeconds: farSideSeconds, micSeconds: micSeconds)
        diagnosticsLog?.write(String(
            format: "substitute mic check: %.0fs of far-side speech, %.1fs heard on the mic -> %@",
            farSideSeconds, micSeconds,
            deaf ? "FALLING BACK to the default input" : "keeping it"))
        guard deaf else { return }
        mic.fallBackToDefaultInput()
    }

    private func handleSystem(_ samples: [Float]) {
        if isPaused { return }
        systemRecorder?.append(samples)
        let rms = AudioMonitor.rms(of: samples)
        if rms >= Self.plausibleSpeechLevel {
            voicedLock.lock()
            systemVoicedSeconds += Double(samples.count) / 16_000
            let farSide = systemVoicedSeconds
            let heard = micVoicedSeconds
            let due = !micVerdictReached && farSide >= Self.farSideSecondsBeforeDoubt
            if due { micVerdictReached = true }
            voicedLock.unlock()
            if due {
                DispatchQueue.main.async { [weak self] in
                    self?.judgeSubstituteMic(farSideSeconds: farSide, micSeconds: heard)
                }
            }
        }
        let now = Date()
        if now.timeIntervalSince(systemMeterLast) > 0.033 {
            systemMeterLast = now
            let level = AudioMonitor.displayLevel(rms)
            DispatchQueue.main.async { self.levels.system = level }
        }
        systemStream?.append(samples)
    }

    private func appendError(_ message: String) {
        if let existing = errorMessage {
            errorMessage = existing + "\n" + message
        } else {
            errorMessage = message
        }
    }

    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func displayLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let clamped = max(-60, min(0, db))
        return (clamped + 60) / 60
    }
}
