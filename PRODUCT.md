# Seal

## Product purpose
Private, on-device meeting notes for macOS. Seal listens to a meeting (mic + system audio), transcribes it live on the Mac, and turns it into notes, action items, and follow-ups. A local-first Granola alternative: nothing leaves the Mac unless the user explicitly opts into cloud notes with their own API key.

## Register
product

## Users
- Professionals who take many calls (founders, consultants, sales, recruiters) on Apple-silicon Macs; many are non-technical.
- Privacy-sensitive by instinct or by policy (legal, healthcare, finance). The wedge is "your meetings never leave your Mac."
- They start a recording fast, glance at it rarely, and read the notes afterwards. The notepad is the hero; transcription happens quietly beside it.

## Tone
- Calm, factual, quietly confident; never salesy inside the app.
- Privacy stated as architecture fact, not marketing.
- UI copy: sentence case, short, concrete. Tooltips state consequences ("Stop and save this meeting").

## Strategic principles
- Lightweight, simple, fast — the standing priority. Prefer removing chrome over adding it.
- Native macOS components with Linear-style restraint (see DESIGN.md); no invented affordances for standard tasks.
- Free core stays generous (recording, transcription, notes, search, export); Pro gates advanced AI passes, never history or export.
- No telemetry, ever. The in-app problem report is the only feedback channel.

## Anti-references
- Dashboard-y SaaS clutter, badge noise, permanent status banners.
- Anything that reads as phoning home.
- Electron-style non-native controls.
