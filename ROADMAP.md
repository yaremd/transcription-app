# Seal — shipped vs. planned

Status of every feature, checked against the code on 27 July 2026. Companion to
[`POSITIONING.md`](POSITIONING.md).

**Headline: 20 of the 32 tasks in `LocalScribe-linear-tasks.csv` are done, 2 are
partial, 10 are open** — and 8 of those 10 were filed Low priority. Eight *shipped*
items were filed as "Backlog", so the tracker reads far behind where the product
actually is. A second, larger group of shipped work was never filed at all
(§3). Reconcile the tracker before planning from it.

---

## 1. Shipped

### Capture & recording
| Feature | Notes |
|---|---|
| Dual-stream capture | Mic (AVAudioEngine) + call audio (ScreenCaptureKit), both → 16 kHz mono |
| ⌘N / ⇧⌘R start-and-listen | No pre-flight dialog, no bot invite |
| Pause, resume, discard | Discard confirms first |
| Live waveform | Colored by who's louder — indigo you, green the call |
| Menu-bar item | Start/stop/pause without raising the window |
| Floating recording pill | Always-on-top, timer + level dots + pause, when Seal isn't frontmost |
| Auto-detect meetings | Zoom, Teams, Webex, FaceTime → offers to record; 18 s auto-dismiss, 10 min per-app snooze. **Filed as Backlog · Core polish** |
| Keep-audio toggle | On by default, ~15 MB/hr; deleting a meeting deletes its audio |

### Transcription
| Feature | Notes |
|---|---|
| On-device Whisper (WhisperKit) | Fast (large-v3-turbo) / Accurate (large-v3) toggle |
| Live transcript | Commits on ~0.85 s pause; ordered by audio clock, not decode order |
| Turn merging | Consecutive utterances from one speaker read as a paragraph |
| Silence guard | Adaptive noise floor + hysteresis; stops Whisper hallucinating stock phrases |
| Echo-ghost suppression | Raw mic capture; duplicate "You" lines dropped downstream |
| Language momentum | Per-source tally stops one bad detection flipping a whole meeting |
| Cyrillic marker suppression | ы э ъ ё tokens suppressed when decoding Ukrainian |
| Custom vocabulary | Whisper decoder prompt → works in **any** language |
| Improve transcript | Full re-pass from saved audio with large-v3; keeps notes/tags/actions |

### Notes & intelligence
| Feature | Notes |
|---|---|
| On-device LLM (MLX) | Qwen2.5-Instruct 4-bit; 7B ≥12 GB RAM, 3B below; user never picks |
| Zero-config model download | ~2–4 GB once, visible progress, starts right after onboarding |
| Human-in-the-loop notes | Timestamped jots steer generation |
| Notes ↔ transcript workspace | Click a note's time to jump; tap a line to anchor the next note |
| AI title on Stop | Retried on next open if the model wasn't ready |
| 6 templates | General, 1-on-1, Sales, Interview, Standup, Lecture |
| 5 rewrite presets | Shorter, more detail, more formal, bullets, plain language |
| Speaker-name suggestions | Proposed from self-intros; never applied without a click |
| Action items | Per meeting + cross-meeting inbox. **Filed as Backlog · Phase 4** |
| Follow-up draft | Copy-out only, never sent. **Filed as Backlog · Phase 4** |
| Ask this meeting | Docked chat over the transcript. **Filed as Backlog · Phase 3** |
| Script-leak retry | Regenerates once if the small model leaks another script |

### Library & export
| Feature | Notes |
|---|---|
| Local persistence | Plain JSON, one file per meeting, user-inspectable |
| Library view | Grouped Today / Yesterday / Previous 7 days / Older |
| Full-text search | Titles, notes, tags, and every transcript line |
| Tags | Add/remove per meeting, searchable |
| Export | Markdown, PDF, clipboard |
| Delete with confirmation | Takes the audio with it, so it always asks |

### Trust & platform
| Feature | Notes |
|---|---|
| Privacy badge | Green local / amber cloud, always on screen |
| Opt-in BYO-key cloud notes | Off by default; transcript text only, never audio; any OpenAI-compatible endpoint |
| Keychain key storage | Plus migration off legacy UserDefaults |
| Onboarding | Sets expectations, primes the permission prompts |
| Appearance | System / light / dark |
| Sparkle auto-update | v0.1 live in the appcast |
| Signing & notarization | Developer ID, Hardened Runtime, minimal non-sandboxed entitlements |
| Apple-silicon tuning | MLX + RAM-based model selection. **Filed as Backlog · Core polish** |
| Tight-RAM coordination | Speech model released before the notes model loads |
| LocalScribe → Seal migration | Meetings folder + Keychain service, one-time |

---

## 2. Partially done

| Item | What exists | What's missing |
|---|---|---|
| **Organize meetings** | Tags, date grouping, search across tags | Folders; grouping by person |
| **Editable rich-text notes** | Notes are editable and persist | It's a plain-text/Markdown editor — no rich-text formatting |

Neither gap is user-blocking. Both are cheap to close if they come up in feedback.

---

## 3. Shipped but never tracked

Substantial work that isn't in the CSV at all, which is most of why the tracker
undercounts:

- The entire multilingual robustness layer — language momentum, Cyrillic marker
  suppression, script-leak retry, vocabulary-as-decoder-prompt
- Silence/hallucination guard and echo-ghost suppression
- Audio-clock ordering and turn merging
- "Improve transcript" second pass
- Speaker-name suggestion flow
- Notes ↔ transcript workspace with timestamp anchoring
- Floating pill, live waveform, tags, appearance, keep-audio toggle, delete
  confirmation, Fast/Accurate toggle
- Sparkle auto-update, Keychain storage, the LocalScribe → Seal rename migration

---

## 4. Open — recommended order

Reordered from the CSV by competitive leverage rather than by original phase.

### Next
1. **Calendar & Contacts integration** *(CSV: Low, Phase 5)* — **should be the top
   item.** It's our most-felt gap against every competitor: meetings aren't
   auto-titled from the invite and attendees aren't named. It also feeds the
   speaker-name flow that already exists, so it's cheaper than it looks. Promote it.
2. **Core Audio process tap** *(CSV: Medium, Phase 2)* — replaces ScreenCaptureKit and
   removes the Screen Recording permission prompt. This is a **positioning fix**, not
   just a technical one: asking for screen access on first run directly undercuts the
   privacy pitch at the worst possible moment. `SystemAudioCapturer` is written as a
   single swappable file, so nothing else changes.
3. **Finish the two partials** — folders, and rich-text notes. Small, and they close
   out Phase 1 properly.

### Then
4. **In-person mode** *(single-mic diarization)* — the one capture scenario we can't
   handle. Opens up non-call meetings entirely, but needs a diarization model.
5. **Semantic search** *(local embeddings)* — meaningful once users have a few months
   of history; not before.
6. **Cross-meeting memory** — people, recurring topics, decisions across meetings.
   The most differentiated of the remaining AI features, and the most expensive.
7. **Obsidian / Notion export** — cheap, and it fits the "your data is yours" story
   better than any cloud integration does.

### Later / reconsider
8. **Morning brief / daily digest** — depends on 6 being good first.
9. **Inline suggestions** *(task rollover, recurrence, delegation)* — nice-to-have.
10. **Slack / Gmail actions** — the first feature that would *send* something on the
    user's behalf. It cuts against the copy-out-only stance the follow-up draft
    deliberately takes. If we do it, it needs to stay explicitly user-triggered.
11. **Encrypted cross-device sync** — the only item needing server infrastructure,
    which is exactly what "we don't have a server" currently buys us. Estimated 8
    points and it complicates the core claim. I'd hold this indefinitely.

---

## 5. Deliberately not doing

Called out so they don't get re-litigated: team workspaces, CRM sync, per-seat
sharing, Windows/Linux, and any bot that joins the call. Each of these contradicts
either the privacy architecture or the single-user focus. See
[`POSITIONING.md`](POSITIONING.md) §6.
