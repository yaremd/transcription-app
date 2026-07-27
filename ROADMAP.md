# Seal — shipped vs. planned

Status of every feature, checked against the code on 27 July 2026. Companion to
[`POSITIONING.md`](POSITIONING.md).

> **Source of truth is Linear** (project *Seal*, team `YAR`), not
> `LocalScribe-linear-tasks.csv`. The CSV is the original 32-item import and is now
> superseded — Linear carries **61 issues**, including all the work listed in §3 that
> the CSV never had. Treat the CSV as a historical artifact.

**Live status after the 27 Jul re-prioritization: 28 Done, 15 In Review, 18 Backlog.**

Two **Urgent** bugs (YAR-70, YAR-71) were sitting in Backlog. Both falsify public
claims on the landing page, so they outrank every feature below — see §0.

---

## 0. Ship-blockers — do these first

Both are Urgent, both are one constructor call in one file, and both should ship
together with a single runtime verification pass.

| Issue | Problem | Why it outranks features |
|---|---|---|
| **YAR-70** | Whisper model load always hits the network — no local-first path | Falsifies **"Works offline"**, a headline claim on the landing page |
| **YAR-71** | Whisper weights download to `~/Documents/huggingface` — 9.2 GB, iCloud-synced for many users | Falsifies the spirit of **"nothing leaves your Mac"** for the app whose entire pitch is that |

Both trace to `Sources/Transcriber.swift:105`, which builds `WhisperKitConfig` with no
`downloadBase` and no cached-model check. The codebase already solved this once:
`Sources/MLXEngine.swift:188` deliberately points its `HubApi` at
`Application Support/Seal/models` — *"so they persist and stay out of the user's
visible Documents folder."* `Transcriber` and `TranscriptPolisher` just never got the
same treatment. YAR-71 needs a migration, or every existing user re-downloads several GB.

**YAR-72** (pre-launch landing page truthfulness) is now marked **blocked by both** —
the page cannot honestly claim offline support until YAR-70 ships. Its own audit found
more: "nothing to opt out of" is false while Sparkle's `SUEnableAutomaticChecks`
suppresses first-run consent with no Settings toggle, and the DMG has no `/Applications`
symlink to drag to.

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

## 4. Open — priority as now set in Linear

Reordered by competitive leverage rather than by original phase. Priorities below were
applied to Linear on 27 Jul 2026.

### Urgent — ship-blockers
| Issue | | Change |
|---|---|---|
| YAR-70 | Offline transcription broken | unchanged (already Urgent) |
| YAR-71 | Models in `~/Documents`, 9.2 GB, iCloud | unchanged (already Urgent) |

### High — the next build order
| Issue | | Change | Why |
|---|---|---|---|
| YAR-72 | Pre-launch landing page truthfulness | unchanged; **now blocked by YAR-70 + YAR-71** | Can't publish claims the build doesn't meet |
| YAR-36 | Calendar & Contacts | **Low → High** | Our most-felt gap against Granola, Otter *and* Hyprnote. Meetings aren't auto-titled from the invite; attendees aren't named. Feeds the speaker-name flow that already exists, so it's cheaper than its 3-point estimate suggests |
| YAR-26 | Core Audio process tap | **Medium → High** | A **positioning** fix, not a technical one — asking for Screen Recording on first run undercuts the privacy pitch at the worst moment. `SystemAudioCapturer` is one swappable file |
| YAR-46 | QA: Phase 2–4 acceptance | **Medium → High** | 15 issues sit In Review, code-complete but not runtime-verified. That queue has to clear before v0.2 |

### Medium
| Issue | | Change |
|---|---|---|
| YAR-40 | In-person mode (single-mic diarization) | **Low → Medium** |
| YAR-68 | Real Whisper download % in first-run banner | **Low → Medium** — same load path as YAR-70/71, do it in that pass |
| YAR-45 | True system-wide global hotkey | **Low → Medium** |
| YAR-37 | Obsidian / Notion export | **Low → Medium** — cheap, and it fits "your data is yours" better than any cloud integration |
| YAR-50 | Hybrid decoding (turbo live, large-v3 committed) | unchanged |

### Low — unchanged
YAR-29 cross-meeting memory · YAR-30 semantic search · YAR-33 morning brief ·
YAR-35 inline suggestions

### Low — and worth a second thought before building
- **YAR-38 Slack / Gmail actions** — the first feature that would *send* something on
  the user's behalf, cutting against the copy-out-only stance the follow-up draft takes
  deliberately. If built, keep it explicitly user-triggered.
- **YAR-39 Encrypted cross-device sync** — the only item needing server infrastructure,
  which is exactly what "we don't have a server" currently buys us. 8 points, and it
  complicates the core claim. Recommend holding indefinitely.

### Also still open
- **The two partials** from §2 — folders, and rich-text notes. Small; they close out
  Phase 1 properly.
- **YAR-59** wax-seal stop animation — left at No priority, as you called it.

---

## 5. Deliberately not doing

Called out so they don't get re-litigated: team workspaces, CRM sync, per-seat
sharing, Windows/Linux, and any bot that joins the call. Each of these contradicts
either the privacy architecture or the single-user focus. See
[`POSITIONING.md`](POSITIONING.md) §6.
