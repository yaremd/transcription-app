#!/usr/bin/env python3
"""Copies docs/ into a self-contained review build: root-relative links become file-relative
(so the pages work inside a claude.ai artifact), fonts come from Google Fonts for the preview
only, and the website analytics key is blanked so review clicks are never counted.
Usage: python3 redesign/build_preview.py <out-dir>"""
import os, re, shutil, sys
from pathlib import Path
DOCS = Path(__file__).resolve().parent.parent / "docs"
OUT = Path(sys.argv[1]).resolve()
PAGES = ["index.html", "404.html", "privacy/index.html", "granola-alternative/index.html", "otter-ai-alternative/index.html",
         "meeting-notes-without-bots/index.html", "local-meeting-notes-mac/index.html"]
FONTS = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Instrument+Sans:wdth,wght@75..100,400..700&family=JetBrains+Mono:wght@400..700&display=swap">'
if OUT.exists():
    shutil.rmtree(OUT)
OUT.mkdir(parents=True)
for p in ["site.js", "favicon.png", "apple-touch-icon.png"]:
    shutil.copy2(DOCS / p, OUT / p)
shutil.copytree(DOCS / "assets", OUT / "assets")
css = (DOCS / "site.css").read_text(encoding="utf-8")
css = re.sub(r"/\* @fonts-start.*?/\* @fonts-end \*/", "/* fonts: Google Fonts in the review build */", css, flags=re.S)
(OUT / "site.css").write_text(css, encoding="utf-8")

def rel(page, target):
    path, frag = (target.split("#", 1) + [""])[:2]
    if path == "" and frag:
        return "#" + frag
    if path.endswith("/"):
        path += "index.html"
    r = os.path.relpath(path.lstrip("/"), os.path.dirname(page) or ".")
    return r + ("#" + frag if frag else "")

for page in PAGES:
    html = (DOCS / page).read_text(encoding="utf-8")
    html = re.sub(r'(href|src)="(/(?!/)[^"]*)"', lambda m: f'{m.group(1)}="{rel(page, m.group(2))}"', html)
    html = html.replace("<head>", "<head>\n" + FONTS, 1)
    html = re.sub(r"var POSTHOG_KEY = '[^']*';", "var POSTHOG_KEY = '';  // blank in the review build", html)
    dest = OUT / page
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(html, encoding="utf-8")
print("preview built:", sum(1 for _ in OUT.rglob("*") if _.is_file()), "files")
