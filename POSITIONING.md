# Seal — features & positioning

What we've built, and the argument for why someone picks it over the alternatives.

Companion docs: [`Brand/BRAND.md`](Brand/BRAND.md) (identity), [`DISTRIBUTION.md`](DISTRIBUTION.md)
(shipping). Competitor pricing here was checked in **July 2026** — re-verify before
putting any of it on the website.

---

## 1. The one-liner

> **Seal is a meeting notepad that records, transcribes, and writes up your calls
> entirely on your Mac.** No bot joins the call, no account, no server to send
> anything to.

The promise, in brand terms: *what's said here stays here.*

The three claims that carry the product, in priority order:

1. **Nothing leaves your Mac.** Not the audio, not the transcript, not the notes.
2. **No bot in your meeting.** Nobody on the call knows you're taking notes.
3. **You jot, it writes.** Your rough notes steer the AI, they don't compete with it.

Claim 1 is the moat. Claims 2 and 3 are table stakes against the tool people are
most likely already using (Granola).

---

## 2. What we've shipped

Everything below is in the codebase today, not roadmap.

### Capture
- **Dual-stream recording** — the microphone (`MicCapturer`, AVAudioEngine) and the
  call's own audio (`SystemAudioCapturer`, ScreenCaptureKit), both resampled to
  16 kHz mono. You and the other side are captured separately, which is what makes
  the two-speaker split work without a diarization model.
- **⌘N starts a meeting and listens immediately.** No pre-flight dialog, no "add to
  calendar", no bot invite. ⇧⌘R toggles from anywhere.
- **Meeting detection** — when Zoom, Teams, Webex, or FaceTime comes to the front, a
  small floating panel offers to record. It never starts on its own, auto-dismisses
  after 18 seconds, and snoozes 10 minutes per app so it can't nag.
- **Pause, resume, discard**, plus a live scrolling waveform colored by who's
  currently louder — indigo for you, green for the call — so a glance confirms both
  sides are actually being heard.
- **Menu-bar item and a floating pill.** Switch apps mid-meeting and a small
  always-on-top pill with a timer, live level dots, and a pause button proves Seal is
  still listening.
- **Audio retention is a setting.** On by default (~15 MB/hour, stored next to the
  meeting JSON), and turning it off is one toggle. Deleting a meeting deletes its audio.

### Transcription
- **On-device Whisper** via WhisperKit. Two speed modes: *Fast* (large-v3-turbo) and
  *Accurate* (full large-v3).
- **Live transcript** that commits utterances on a ~0.85 s pause, orders lines by the
  capture stream's own audio clock rather than by decode-completion order, and merges
  consecutive utterances from one speaker into a readable paragraph.
- **Silence is never transcribed.** An adaptive noise-floor threshold with hysteresis
  keeps Whisper from hallucinating its stock phrases ("Thank you", "Дякую!") into quiet
  audio — a failure mode that plagues naive Whisper wrappers.
- **Echo suppression without voice processing.** macOS's echo canceller destroyed
  speech on this hardware, so the mic is captured raw and "You" lines that duplicate a
  recent "Others" line are dropped downstream instead.
- **Multilingual with language momentum.** English, Ukrainian, or auto-detect
  restricted to those two — unrestricted auto-detect lets Whisper mishear accented
  speech as Malay and then *translate* into it. A per-source language tally keeps one
  noisy detection from flipping a Ukrainian meeting into English, and tokens containing
  letters Ukrainian never uses (ы э ъ ё) are suppressed when decoding Ukrainian.
- **Custom vocabulary** — names, acronyms, and jargon, applied as a Whisper decoder
  prompt, so it works in **any** language. (Granola's equivalent is English-only.)
- **"Improve transcript"** — re-transcribes a finished meeting from its saved audio
  with the accurate model and full context, replacing the rough live lines while
  keeping notes, tags, and action items. Live optimizes for speed; this pass optimizes
  for the record.

### Notes
- **On-device LLM** via MLX — Qwen2.5-Instruct 4-bit, 7B on Macs with ≥12 GB RAM and
  3B below. The user never picks a model; it downloads once (~2–4 GB) on first use with
  visible progress, and there is no Ollama, no terminal, no API key.
- **Human-in-the-loop notes.** Type rough jots while you talk; each is timestamped and
  anchored to the moment of the conversation it was written in. On Stop, Seal titles the
  meeting and writes full notes from the transcript, guided by your jots.
- **Notes ↔ transcript workspace** — your timestamped notes on the left, the full
  transcript on the right. Click a note's time to scroll and highlight that moment; tap
  a transcript line to anchor the next note.
- **Six templates** — General, 1-on-1, Sales call, Interview, Standup, Lecture — each
  with its own section headings and model guidance.
- **Rewrite presets** — shorter, more detail, more formal, bullet points, plain
  language. Notes are also directly editable, and edits persist.
- **Speaker names.** The model reads self-introductions and forms of address and
  *proposes* real names for "You"/"Others". It never applies them without a click, and
  declining is remembered.
- **Action items**, extracted per meeting and collected into a cross-meeting inbox
  grouped by source meeting, with check-off that saves back to the meeting.
- **Follow-up drafts** — generates the follow-up message; you copy it out. Nothing is
  ever sent automatically.
- **"Ask this meeting"** — a docked chat over the transcript, ephemeral, cleared on
  leaving.
- **Language-leak guard.** If the small local model leaks a run of another script into
  long notes, generation is retried once automatically.

### Library
- Meetings saved as **plain JSON**, one file per meeting, in
  `~/Library/Application Support/Seal/Meetings` — inspectable, backup-able, and yours.
- Sidebar grouped Today / Yesterday / Previous 7 days / Older; full-text search across
  titles, notes, tags, and every transcript line.
- Tags per meeting; unnamed meetings show a content preview instead of a wall of
  identical "New transcription" rows.
- Export to **Markdown, PDF, or clipboard**; delete asks first, because it takes the
  audio with it.

### Trust & platform
- **Privacy badge** in the UI: a green dot when fully local, amber when the opt-in
  cloud notes model is on. The state is always visible, never buried in settings.
- **Opt-in cloud notes, BYO key.** Off by default. When on, only the *transcript text*
  goes out — never audio — and transcription always stays on-device. Any
  OpenAI-compatible endpoint (OpenAI, OpenRouter, Groq, LM Studio). The key lives in the
  macOS Keychain, not UserDefaults.
- Native SwiftUI, light/dark/system, first-run onboarding, Sparkle auto-updates,
  Developer ID signing + notarization, Hardened Runtime with a minimal non-sandboxed
  entitlements file declaring microphone access only.

### Not built yet — say so honestly
Calendar/Contacts integration, Obsidian/Notion export, cross-device sync, semantic
search, cross-meeting memory, and in-person single-mic diarization are all backlog (see
`LocalScribe-linear-tasks.csv`). Two of these are load-bearing for some buyers:
**no calendar integration** means meetings aren't auto-titled from invites or matched to
attendees, and **no in-person mode** means two people sharing one microphone are not
separated. Don't let the website imply otherwise.

---

## 3. The market, in four camps

**Camp 1 — Bot notetakers.** Otter.ai, Fireflies, Fathom, tl;dv, Read.ai.
A visible participant joins the call, recording goes to their cloud, an LLM summarizes
it there. Roughly $10–30/user/month; Fathom is free for individuals. Strong on CRM
integrations and team workflows.
**Their weakness:** everyone on the call sees the bot, and everything you say lives on
someone else's servers under someone else's retention policy.

**Camp 2 — Bot-free cloud.** Granola, Circleback, and the newer "no bot" tools.
Granola defined the category we're closest to: capture from the desktop, no bot, jot
during the call, AI expands your notes afterward. Business is ~$14/user/month, Enterprise
~$35. They don't store audio or video, and they're SOC-2 and GDPR compliant — but
transcript and notes still go to their US-hosted AWS VPC, and it needs an account.
**Their weakness:** the privacy story is a *policy*, not an architecture. It requires
trusting a company, a jurisdiction, and a retention setting.

**Camp 3 — Local-first meeting notepads.** Hyprnote (open source, Mac, Whisper +
local LLM, free), Meetily, and assorted GitHub projects.
**This is our real competition.** Hyprnote makes the same core claim we do, is free and
open source, and already ships Calendar/Contacts/Obsidian integrations we don't have.
**Their weakness:** open-source rough edges, no signed-and-notarized commercial polish,
and — for our specific user — no serious Ukrainian/mixed-language handling.

**Camp 4 — Local transcription utilities.** MacWhisper (€59 lifetime), Superwhisper
($8.49/mo or $249 lifetime), Aiko (free), VoiceInk.
These are dictation and file-transcription tools, not meeting products. They give you
text, not notes, action items, or a searchable meeting library.
**Their weakness:** wrong shape for the job. Nobody's meeting workflow ends at a
transcript.

Also in the frame but rarely the real alternative: Zoom AI Companion, Teams Recap, and
Notion AI meeting notes — free-in-the-box, cloud, and locked to one platform.

---

## 4. Head-to-head

| | **Seal** | Granola | Otter / Fathom | Hyprnote | MacWhisper |
|---|---|---|---|---|---|
| Audio stays on device | ✅ | ✅ (not stored) | ❌ | ✅ | ✅ |
| Transcript stays on device | ✅ | ❌ cloud | ❌ cloud | ✅ | ✅ |
| Notes generated on device | ✅ | ❌ cloud | ❌ cloud | ✅ | n/a |
| Works fully offline | ✅ | ❌ | ❌ | ✅ | ✅ |
| No account required | ✅ | ❌ | ❌ | ✅ | ✅ |
| No bot in the call | ✅ | ✅ | ❌ | ✅ | n/a |
| Jot-then-AI-expands | ✅ | ✅ | ❌ | ✅ | ❌ |
| Meeting library + search | ✅ | ✅ | ✅ | ✅ | ❌ |
| Action items / follow-ups | ✅ | ✅ | ✅ | ✅ | ❌ |
| Custom vocabulary, any language | ✅ | ⚠️ English only | ⚠️ | ⚠️ | ⚠️ |
| Ukrainian / mixed-language tuning | ✅ | ❌ | ⚠️ | ❌ | ⚠️ |
| Calendar / Contacts | ❌ | ✅ | ✅ | ✅ | ❌ |
| Team sharing & CRM | ❌ | ✅ | ✅ | ❌ | ❌ |
| Price | one-time / free | ~$14–35/user/mo | $0–30/user/mo | free, OSS | €59 lifetime |

---

## 5. Where we win, where we lose

**We win on:**
1. **Architecture, not policy.** We don't have a server to send meetings to. There's no
   retention setting to trust because there's no retention. That's a categorically
   different claim from "SOC-2 compliant" and it's the only one that survives a
   security review at a law firm, a clinic, or a company's M&A team.
2. **Sensitive conversations.** Legal, medical, therapy, HR, salary talks, board and
   investor calls, interviews, due diligence. For these, cloud tools aren't merely
   uncomfortable — they're often contractually or legally prohibited.
3. **Actually offline.** Planes, trains, secure facilities, bad hotel wifi. After the
   one-time model download, everything works with the network off.
4. **Ukrainian and mixed-language meetings.** Nobody in camps 1–3 has done the work:
   language momentum per source, Cyrillic marker-token suppression, script-leak retry in
   notes, vocabulary as a decoder prompt so it biases in any language. This is a real,
   defensible, currently-unserved wedge.
5. **No subscription.** A one-time or free local app against $14–35/user/month
   recurring, with no per-seat math and no usage caps.

**We lose on:**
1. **Team features.** No sharing, no workspace, no CRM push. A sales org buying seats
   is not our customer, and we shouldn't pretend otherwise.
2. **Calendar/Contacts.** Competitors auto-title meetings and name attendees from the
   invite; we ask you to type ⌘N. This is our most-felt gap and the highest-leverage
   thing on the backlog.
3. **Note quality ceiling.** A 4-bit 3B/7B running on a laptop will not out-write a
   frontier model on a long, messy call. The BYO-key toggle is the honest escape hatch
   — and the fact that it's *off by default and transcript-only* is itself a proof
   point.
4. **Hardware floor.** On-device notes need Apple silicon and real RAM; Intel Macs get
   transcription plus the cloud option only. Say this plainly on the download page —
   we already do.
5. **Setup weight.** A 2–4 GB first-run download versus a cloud tool's instant signup.
   Mitigated by starting the fetch right after onboarding, but it's still a real cost.
6. **Free and open source.** Hyprnote costs nothing and can be audited. Our answer has
   to be polish, notarized distribution, and language handling — not secrecy.

---

## 6. Who it's for

**Primary:** an individual professional on an Apple-silicon Mac whose meetings contain
things that must not be uploaded — a lawyer, therapist, doctor, recruiter, founder,
consultant, or executive. They already know cloud notetakers exist and have decided
against them, or use one and feel uneasy about it.

**Secondary:** Ukrainian and Ukrainian/English bilingual professionals, for whom every
Western tool transcribes badly and every local tool transcribes worse. Smaller market,
near-zero competition, and the users are unusually loud when something finally works.

**Tertiary:** privacy-minded technical users who'd otherwise be assembling Whisper and
Ollama by hand, and want the assembled thing.

**Not for us:** sales teams needing CRM sync, distributed teams needing shared meeting
workspaces, Windows or Linux users, anyone whose main need is a searchable team archive.

**The wedge:** land on privacy and language, expand into the meeting library and action
items once people have a month of meetings in it. The switching cost we build isn't
lock-in — it's that their history is already here, in plain JSON they own.

---

## 7. Messaging

**Lead with the architecture, not the adjective.** "Private by architecture, not by
promise" beats "secure and private" because it's falsifiable and competitors can't copy
the sentence.

**The proof points, in order of persuasive power:**
1. There is no server. Nothing to opt out of, nothing to configure, no account.
2. Turn off the wifi and it still works.
3. Your meetings are plain JSON files in a folder you can open right now.
4. The privacy badge is on screen the whole time and turns amber the moment anything
   would leave.
5. No bot appears in the participant list.

**Against Granola specifically** — don't attack them, extend them. They taught the
market the jot-then-expand interaction; we agree with it and moved the compute. The
line is: *"Granola without the cloud."* One sentence, immediately understood by anyone
who's used it, and it makes their marketing budget work for us.

**Against Hyprnote** — never on privacy, we tie. Compete on being a finished product:
signed, notarized, auto-updating, designed, and the only one that handles Ukrainian.

**Don't claim:** end-to-end encryption (there's no transport to encrypt), "AI that
knows your whole work life" (no cross-meeting memory yet), HIPAA/GDPR compliance
(we're not a processor — the correct framing is that we're *out of scope* because no
data is transferred), or anything about team collaboration.

**Do say clearly:** Apple-silicon Mac needed for on-device notes; one-time model
download; macOS 14+.

---

## 8. Risks to the position

- **Apple ships it.** On-device summarization in Notes or a system-level meeting recap
  would compress the whole category. Our hedge is depth — templates, action items,
  language handling, the notes↔transcript workspace — which platform features
  historically don't reach.
- **Granola or a rival ships a local mode.** They'd need to give up the server-side
  product surface that justifies the subscription, so it's unlikely but not impossible.
  Our answer would be that we're local-*only*, with nothing to switch off.
- **Local model quality stalls** while frontier models pull further ahead, widening the
  perceived gap in note quality. Mitigation: keep the on-device model current, keep the
  BYO-key escape hatch honest and visible.
- **Hyprnote out-executes us on integrations** while matching the privacy claim. This is
  the most likely of the four. Calendar/Contacts is the correct next investment.
- **The ScreenCaptureKit permission.** Asking for Screen Recording to capture audio
  reads as invasive and directly undercuts the pitch on first run. The Core Audio
  process tap on the backlog is a *positioning* fix, not just a technical one.
