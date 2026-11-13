#!/usr/bin/env python3
"""Builds the Sealed Glass site into docs/ from the live site on `main`.

What it keeps, byte for byte, from main:docs/ — so search, analytics and the update emails
behave exactly as they do today:
  * every page's <head> SEO (title, description, canonical, Open Graph, Twitter, icons,
    google-site-verification) and JSON-LD,
  * the home page's FAQ (it is mirrored in its FAQPage JSON-LD) and its three scripts
    (PostHog website measurement, download-click tracking, the Buttondown form),
  * every article's <main> content: crumbs, page hero, prose, tables, FAQ, read-next, end CTA.
What it changes: the stylesheet, colour scheme, header and footer, and the home page body.

Run from the worktree root:  python3 redesign/build_site.py
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
TEMPLATE = ROOT / "redesign" / "home.template.html"
ARTICLES = ["privacy/index.html", "granola-alternative/index.html", "otter-ai-alternative/index.html",
            "meeting-notes-without-bots/index.html", "local-meeting-notes-mac/index.html", "404.html"]
DMG = "https://github.com/yaremd/transcription-app/releases/latest/download/Seal.dmg"


def from_main(rel):
    return subprocess.run(["git", "-C", str(ROOT), "show", f"main:docs/{rel}"], check=True,
                          capture_output=True, text=True).stdout


def one(pattern, text, flags=re.S):
    m = re.search(pattern, text, flags)
    if not m:
        sys.exit(f"build_site: pattern not found: {pattern[:70]}")
    return m


def restyle_head(head, home=False):
    head = re.sub(r"\s*<style>.*?</style>", "", head, flags=re.S)
    head = re.sub(r'\s*<link rel="stylesheet" href="/styles\.css">', "", head)
    head = head.replace('<meta name="color-scheme" content="light">', '<meta name="color-scheme" content="dark">')
    head = re.sub(r'<meta name="theme-color" content="[^"]*">', '<meta name="theme-color" content="#04110D">', head)
    if '<meta name="color-scheme"' not in head:
        head = head.replace('<meta name="viewport"', '<meta name="color-scheme" content="dark">\n<meta name="viewport"', 1)
    if '<meta name="theme-color"' not in head:
        head = head.replace('<meta name="viewport"', '<meta name="theme-color" content="#04110D">\n<meta name="viewport"', 1)
    if home:
        head = head.replace('"softwareVersion": "0.24"', '"softwareVersion": "1.5"')
    return head.strip()


SPRITE = '''<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false"><defs><symbol id="seal" viewBox="0 0 240 240"><path fill="currentColor" fill-rule="evenodd" d="M200 120C200 164.18 164.18 200 120 200C75.82 200 40 164.18 40 120C40 75.82 75.82 40 120 40C164.18 40 200 75.82 200 120ZM99 104C99 113.94 90.94 122 81 122C71.06 122 63 113.94 63 104C63 94.06 71.06 86 81 86C90.94 86 99 94.06 99 104ZM177 104C177 113.94 168.94 122 159 122C149.06 122 141 113.94 141 104C141 94.06 149.06 86 159 86C168.94 86 177 94.06 177 104ZM104 142Q104 134 112.5 134Q117 134 120 139Q123 134 127.5 134Q136 134 136 142Q136 150.5 125.5 156.5Q120 159.5 114.5 156.5Q104 150.5 104 142ZM94.53 144.04C81.7 146.06 69.21 149.1 57.05 153.15C55.48 153.68 54.63 155.38 55.15 156.95C55.68 158.52 57.38 159.37 58.95 158.85C70.79 154.9 82.96 151.94 95.47 149.96C97.1 149.7 98.22 148.17 97.96 146.53C97.7 144.9 96.17 143.78 94.53 144.04ZM95.51 154.4C86.04 159.81 77.57 165.57 70.1 171.68C68.82 172.73 68.63 174.62 69.68 175.9C70.73 177.18 72.62 177.37 73.9 176.32C81.1 170.43 89.3 164.86 98.49 159.6C99.93 158.78 100.43 156.95 99.6 155.51C98.78 154.07 96.95 153.57 95.51 154.4ZM144.53 149.96C157.04 151.94 169.21 154.9 181.05 158.85C182.62 159.37 184.32 158.52 184.85 156.95C185.37 155.38 184.52 153.68 182.95 153.15C170.79 149.1 158.3 146.06 145.47 144.04C143.83 143.78 142.3 144.9 142.04 146.53C141.78 148.17 142.9 149.7 144.53 149.96ZM141.51 159.6C150.7 164.86 158.9 170.43 166.1 176.32C167.38 177.37 169.27 177.18 170.32 175.9C171.37 174.62 171.18 172.73 169.9 171.68C162.43 165.57 153.96 159.81 144.49 154.4C143.05 153.57 141.22 154.07 140.4 155.51C139.57 156.95 140.07 158.78 141.51 159.6Z"/></symbol></defs></svg>'''


def article_nav(current):
    links = [("/#features", "How it works"), ("/privacy/", "Privacy"), ("/#compare", "Compare"), ("/#faq", "FAQ")]
    cur = ' aria-current="page"'
    items = "".join('<a href="{}"{}>{}</a>'.format(h, cur if h == current else "", t) for h, t in links)
    return f'''<a class="skip" href="#main">Skip to content</a>
<header class="nav">
  <div class="wrap nav-in">
    <a class="brand" href="/" aria-label="Seal home"><svg aria-hidden="true"><use href="#seal"/></svg>Seal</a>
    <nav class="nav-links" aria-label="Site">{items}</nav>
    <a class="btn small" href="{DMG}">Download free</a>
  </div>
</header>'''


FOOTER = f'''<footer class="footer">
  <div class="wrap">
    <div class="footer-grid">
      <div><a class="brand" href="/"><svg aria-hidden="true"><use href="#seal"/></svg>Seal</a><p class="about">Private meeting notes for macOS. Recording, transcription and notes run entirely on your Mac.</p></div>
      <div><h4>Product</h4><ul><li><a href="/#features">How it works</a></li><li><a href="/#privacy">Privacy</a></li><li><a href="/#compare">Compare</a></li><li><a href="/#faq">FAQ</a></li></ul></div>
      <div><h4>Compare</h4><ul><li><a href="/granola-alternative/">vs Granola</a></li><li><a href="/otter-ai-alternative/">vs Otter.ai</a></li><li><a href="/meeting-notes-without-bots/">Without bots</a></li><li><a href="/local-meeting-notes-mac/">Local notes on Mac</a></li></ul></div>
      <div><h4>Privacy</h4><ul><li><a href="/privacy/">What Seal sends</a></li><li><a href="/#privacy">How it stays private</a></li></ul></div>
      <div><h4>Get Seal</h4><ul><li><a href="{DMG}">Download for Mac</a></li><li><a href="https://github.com/yaremd/transcription-app">Source on GitHub</a></li></ul></div>
    </div>
    <div class="legal"><span>Seal · Private meeting notes for macOS</span><span>Requires macOS 14 or later; on-device AI notes need an Apple-silicon Mac.</span></div>
  </div>
</footer>'''


def build_home():
    old = from_main("index.html")
    head = restyle_head(one(r"<head>(.*?)</head>", old).group(1), home=True)
    faq_block = one(r'<section id="faq".*?</section>', old).group(0)
    details = re.findall(r"<details>.*?</details>", faq_block, flags=re.S)
    if len(details) != 4:
        sys.exit(f"build_site: expected 4 FAQ items, found {len(details)}")
    faq = []
    for d in details:
        if "<summary>Is Seal really free?</summary>" in d:
            d = d.replace("<details>", '<details id="pricing">', 1)  # the app's old pricing link lands here
        faq.append("        " + d.strip())
    scripts = re.findall(r"<script>(.*?)</script>", old, flags=re.S)
    keep = [s for s in scripts if ("POSTHOG_KEY" in s or "download_clicked" in s or "NEWSLETTER_ENDPOINT" in s and "notify" in s)]
    if len(keep) != 3:
        sys.exit(f"build_site: expected the 3 site scripts, found {len(keep)}")
    page = TEMPLATE.read_text(encoding="utf-8")
    page = page.replace("@@HEAD@@", head).replace("@@FAQ@@", "\n".join(faq))
    page = page.replace("@@SCRIPTS@@", "\n".join(f"<script>{s}</script>" for s in keep))
    (DOCS / "index.html").write_text(page, encoding="utf-8")
    print("index.html: head, FAQ (id=pricing), 3 scripts carried over")


def build_article(rel):
    old = from_main(rel)
    head = restyle_head(one(r"<head>(.*?)</head>", old).group(1))
    body = one(r"<body[^>]*>(.*)</body>", old).group(1)
    main = one(r"<main>(.*?)</main>", body).group(1)
    current = "/privacy/" if rel.startswith("privacy/") else ""
    after_main = body[body.find("</main>") + 7:]
    if "<script" in after_main:
        sys.exit(f"build_site: {rel} has scripts after <main>; handle them before replacing the footer")
    page = f'''<!doctype html>
<html lang="en">
<head>
{head}
<link rel="stylesheet" href="/site.css">
</head>
<body>
{SPRITE}
{article_nav(current)}

<main id="main" class="article">{main}</main>

{FOOTER}
</body>
</html>
'''
    (DOCS / rel).write_text(page, encoding="utf-8")
    print(f"{rel}: restyled, content kept ({len(main)} chars of <main>)")


if __name__ == "__main__":
    build_home()
    for rel in ARTICLES:
        build_article(rel)
