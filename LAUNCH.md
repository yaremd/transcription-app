# Seal launch kit (October 2026)

Everything below is written in your voice, first person, ready to paste. Facts
are current as of Seal 1.3: free, no account, no telemetry in the app, source
public to audit, macOS 14+, Apple silicon.

Links to paste:
- Download: https://sealformac.com
- Source: https://github.com/yaremd/transcription-app

---

## 1. Show HN (Hacker News)

**Title** (80 chars max):

Show HN: Seal – meeting notes that never leave your Mac (no bot, no cloud, free)

**Text:**

I built Seal because I wanted Granola-style meeting notes without a bot in my
calls and without my conversations going to someone's server.

Seal is a native macOS app. It records your microphone and the call's audio from
the Mac itself, so nothing joins the meeting. Transcription runs on-device with
Whisper (WhisperKit), the notes are written by an on-device model (Qwen 2.5 via
MLX), and speaker split uses pyannote through FluidAudio. It works with Wi-Fi
off. There is no account, no server, and no analytics code in the app.

What it does during a meeting: live transcript, your own notes stamped with the
moment you typed them, and "Ask", which answers questions from everything said
so far ("what did they just say?", "what's been decided?"). The model keeps the
transcript it has already read in its KV cache, so a question an hour in is
answered in a few seconds. You can also snap the screen: the slide or document
on it is read with Vision OCR and goes into the notes as context.

After: notes with your lines in ink and the model's in a quieter ink, speaker
names, action items, follow-up drafts, templates, search, folders, and export to
Markdown, PDF, Word, SRT and VTT.

The source is public so the privacy claim can be checked rather than trusted:
the only network calls are the update check, the first-run model download, and
optional licence activation, and none of them carry meeting content. It is
source-available, not open source.

Honest limits: Apple silicon only; the first run downloads about 1.5 GB for
speech and 2 to 4 GB for the notes model; a 7B model writes good notes, not
frontier-model notes (you can plug in your own API key if you want that, off by
default); built for English and Ukrainian meetings first.

It's free. I'm a solo developer in Ukraine and would genuinely like to hear
where it breaks. There is no telemetry, so the in-app "Report a problem" and
GitHub issues are the only ways I find out.

https://sealformac.com

---

## 2. Product Hunt

**Name:** Seal

**Tagline** (60 chars max):

Private meeting notes, entirely on your Mac. Free.

**Description** (260 chars max):

Seal records your mic and the call's audio from the Mac itself, transcribes
live, writes notes, names speakers and answers questions about the meeting,
all on-device. No bot in the call, no account, no cloud, no telemetry. Free.
macOS 14+, Apple silicon.

**Topics:** Productivity, Mac, Privacy, Artificial Intelligence, Meetings

**Maker's first comment:**

Hi everyone, I'm Dmytro, the person behind Seal.

I take a lot of calls and wanted notes without a bot announcing itself to
everyone and without my conversations leaving my machine. Every tool I tried
sent the audio somewhere. So I built one that doesn't.

Seal listens from your Mac, not from the meeting, so it works with Zoom, Meet,
Teams, FaceTime, a phone on speaker, or a lecture. Transcription, notes,
speaker split and "ask the meeting" all run on-device, and the app works
offline. You can ask it questions while the meeting is still happening, and
snap the screen so the slide ends up in your notes.

It's free, there's no account, and the source is public so you can check what
it does with a recording instead of taking my word for it.

What I'd love from you: try it on a real call and tell me what felt wrong.
There's a "Report a problem" item in the app and I read every one.

---

## 3. Reddit (r/macapps, r/privacy, r/productivity)

**Title:**

I made Seal, a free meeting-notes app that runs entirely on your Mac (no bot, no cloud)

**Body:**

Seal records your mic and the call's audio from the Mac itself, so no bot joins
your meetings and nothing is uploaded. It transcribes live, writes the notes,
splits speakers, and lets you ask questions about the meeting, during it or
after. All of it runs on-device; it works with Wi-Fi off.

- Live transcript plus your own timestamped notes
- Ask the meeting anything, even mid-call
- Snap the screen: the slide's text goes into the notes
- Speaker split, action items, follow-up drafts, templates
- Export to Markdown, PDF, Word, SRT, VTT
- No account, no subscription, no telemetry in the app
- Source public for audit (source-available)

Requirements: macOS 14+, Apple silicon. First run downloads the models
(about 1.5 GB speech, 2 to 4 GB notes).

Free: https://sealformac.com

Solo dev, happy to answer anything and to hear what breaks.

---

## 4. X / Twitter (280 chars)

Seal: meeting notes that never leave your Mac. No bot in the call, no cloud,
no account, works offline. Live transcript, on-device notes, speaker split,
ask the meeting mid-call. Free. macOS 14+, Apple silicon. Source public to
audit. https://sealformac.com

---

## 5. LinkedIn

I've shipped Seal, a meeting-notes app for Mac built around one rule: nothing
leaves your machine.

It records your mic and the call's audio from the Mac itself, so no bot joins
the meeting. Transcription, notes, speaker split and "ask the meeting" run
on-device, and the app works offline. If your company has a no-bot or
no-cloud policy for calls, this is the version of AI notes that passes it.

It's free, there's no account, and the source is public so the privacy claim
can be checked rather than trusted.

macOS 14+, Apple silicon: https://sealformac.com

---

## Answers for the questions that will come

**How do I know nothing leaves the Mac?**
The source is public. The only network calls are the update check, the
first-run model download from Hugging Face, and licence activation if you
enter a key. Little Snitch or Lulu will show you the same thing.

**Why is it free?**
It runs on your Mac, so it costs me nothing when you use it. There are no
servers to pay for.

**Will it stay free?** (only if asked; your call on wording)
It's free now and I have no plans to change that. Whatever happens, your
meetings, notes and exports are files on your Mac and the code stays
readable.

**Intel Macs?**
Transcription needs the Apple Neural Engine for speed and the notes model
needs Apple silicon, so no.

**Which languages?**
Built and tested for English and Ukrainian first. Whisper hears many more;
notes are strongest in those two.

**How good are the notes compared with a cloud model?**
Good, not frontier. It's a 7B model on 16 GB+ Macs, 3B on 8 GB. If you want
GPT-class notes you can turn on cloud notes with your own API key; it's off by
default and clearly marked when on.

**Does it record my screen?**
Only when you press the camera button or ⇧⌘S during a recording, one picture
per press, and macOS asks for permission the first time. Nothing streams.
