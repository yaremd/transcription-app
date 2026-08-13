# SEO: what's done, and what only you can do

Last updated 13 August 2026.

The site now has the technical and content foundation to rank. The rest is
off-page work — links, listings, and mentions — which no amount of code can
create. This document is the honest division of labour.

---

## Part 1 — What's already in the repo

Shipped on the `claude/seo-optimization-c14e0a` branch:

- **`docs/robots.txt`** — was returning 404. Allows all search crawlers *and*
  the AI answer engines (GPTBot, ClaudeBot, PerplexityBot, OAI-SearchBot,
  Applebot). People increasingly ask an assistant for "a private meeting notes
  app for Mac"; a blocked crawler can't recommend us.
- **`docs/sitemap.xml`** — was returning 404. Lists all six pages.
- **`docs/404.html`** — a branded not-found page that routes people onward
  instead of dead-ending.
- **`docs/styles.css`** — the homepage's inline CSS, extracted byte-exact so
  every page shares one cached stylesheet. The homepage renders identically.
- **Homepage `<head>`** — keyword-led title, `og:site_name`, `og:locale`,
  `og:image:alt`, full Twitter card set, `max-image-preview:large`.
- **Structured data** — replaced the single blob with a linked graph:
  `Organization`, `WebSite`, a complete `SoftwareApplication` (version,
  feature list, three offers with availability and URLs), and `FAQPage`.
  Every schema question also appears visibly on the page, which Google
  requires.
- **Four new content pages**, each ~1,200–1,700 words with their own schema:
  - `/granola-alternative/`
  - `/otter-ai-alternative/`
  - `/local-meeting-notes-mac/`
  - `/meeting-notes-without-bots/`
- **`/privacy/`** — a real privacy page listing every network connection the
  app makes.

### Why the new pages exist

A single landing page can realistically rank for a handful of queries. The
competitors already ranking in this niche — Muesli, Speechmark, Hapi, Meetily,
Slipbox — all run dedicated `/granola-alternative` style pages. That is the
shape of the category. Seal had none.

### A note on the competitor pages

The Granola and Otter comparisons state facts about named companies in public.
Everything was checked against their own pricing, security, and privacy pages
in August 2026, each table is captioned with that date, and both pages open by
saying what the competitor does *well*. **Please read them before merging** —
they're your public voice, and factual claims about competitors are worth your
own eyes.

Notably, Granola is **not** a bot-based tool — it's bot-free like Seal. The
honest difference is that its audio goes to third-party transcription
providers and its notes live in its US cloud. The page says exactly that.

### On compliance wording

The pages deliberately do **not** claim HIPAA or GDPR compliance. Those
obligations attach to you and your organisation, not to software. What the
pages argue instead — that on-device processing removes the third-party
processor entirely, so there's no vendor receiving the data and no DPA to
negotiate over it — is both accurate and a stronger argument. Please keep it
worded that way.

---

## Part 2 — Do these five things this week

These are worth more than everything above, and I can't do them for you.

### 1. Google Search Console (30 min, highest priority)

Nothing else matters until Google knows the pages exist.

1. Go to <https://search.google.com/search-console>, sign in.
2. Add property → **Domain** → enter `sealformac.com`.
3. It gives you a TXT record. Add it in **Vercel** (that's where your DNS
   lives), then click Verify.
4. Left sidebar → **Sitemaps** → enter `sitemap.xml` → Submit.
5. Use **URL Inspection** on each of the six URLs → "Request indexing".

Then leave it. Check back in two weeks — the Performance tab will show which
queries you're actually appearing for, which is the real input to round two.

### 2. Bing Webmaster Tools (10 min)

<https://www.bing.com/webmasters> — you can import directly from Search
Console. Worth doing because **ChatGPT's web search is powered by Bing's
index**, so this is the fastest route into AI answers.

### 3. AlternativeTo (20 min, unusually high value here)

<https://alternativeto.net> ranked on the first page for "Granola
alternatives" in my research. Submit Seal, list it as an alternative to
Granola, Otter.ai, Fathom, and Fireflies, and make sure the tags include
`privacy`, `offline`, `on-device`, `macos`. This single listing tends to
outrank most small products' own pages for "X alternative" queries.

### 4. Get listed in the roundups that already rank

For a new site, this is where traffic actually comes from. These pages rank
today for the queries you want, and most accept submissions or respond to a
polite email:

| Site | Why it matters |
|---|---|
| alternativeto.net | Ranks page one for "Granola alternatives" |
| fellow.ai/blog/bot-free-ai-note-takers | Ranks for "bot-free note takers" |
| heymumble.com/blog/local-ai-meeting-note-takers-mac | Direct category match |
| voicescriber.com/best-offline-transcription-apps | Direct category match |
| meetjamie.ai/blog/granola-alternatives | Ranks for the money query |
| Slant.co, SaaSHub, Product Hunt | General discovery + links |

A short, non-pushy email works: what Seal is, the one-line difference
(everything on-device, no account), and a link. No pitch deck.

### 5. Launch surfaces (pick your moment)

- **Show HN** — "Show HN: Seal – on-device meeting notes for Mac, no cloud,
  no account". This audience is precisely your wedge. Post Tuesday–Thursday
  morning US time.
- **r/macapps** — very receptive to one-time-purchase native Mac apps.
- **r/privacy**, **r/privacytoolsIO** — lead with the architecture, not the
  product.
- **Product Hunt** — worth one good launch day.
- **privacyguides.org** forum and the `awesome-privacy` GitHub list — both
  are exactly your positioning and both drive durable links.

---

## Part 3 — Honest expectations

I'd rather set these now than have you check rankings on Friday and be
disappointed.

- **Brand queries** ("Seal for Mac", "sealformac") — days, once indexed.
- **Long-tail** ("meeting notes without a bot mac", "offline meeting
  transcription mac") — 1–3 months. Genuinely winnable; low competition and
  the new pages target them directly.
- **"Granola alternative", "Otter.ai alternative"** — 3–6 months, and only
  with links. Six well-established sites already own these, and content alone
  won't displace them. The listings in Part 2 are what moves this.
- **Head terms** ("AI meeting notes", "meeting transcription") — not
  realistic, and not worth chasing. The intent is worse anyway.

**The bottleneck is domain authority, not the site.** sealformac.com was
registered two days ago and has almost no inbound links. Everything in Part 2
is about fixing that; nothing in Part 1 can.

One thing genuinely in your favour: AI answer engines weight *substance and
specificity* far more than domain age. The offline test on
`/local-meeting-notes-mac/` and the connection table on `/privacy/` are the
kind of concrete, checkable detail that gets quoted. That channel may pay off
well before Google does.

---

## Part 4 — Round two, once you have data

Don't build more pages yet. Wait for Search Console to tell you what's
landing, then:

- Pages for the verticals, if the queries show up: `/for/lawyers/`,
  `/for/therapists/`, `/for/journalists/`. Memory says the privacy vertical is
  the wedge — but let the data pick which one.
- More named comparisons: Fathom, Fireflies, Notion AI, Superhuman.
- A `/download/` page, so the download link stops being an off-site GitHub URL.
- Consider privacy-respecting analytics (Plausible or GoatCounter). The
  privacy page currently states the site has none, which is true and worth
  keeping true — but if you add it, **update that page in the same commit.**

---

## Maintenance

Two things go stale and will quietly undermine the pages:

1. **`softwareVersion` in the homepage schema** — currently `0.21`. Bump it
   with each release, or drop the field.
2. **Competitor pricing** in the two comparison tables. Both are captioned
   "checked August 2026". Re-check every few months and move the date, or the
   captions become a liability rather than a credibility marker.
